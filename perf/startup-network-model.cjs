// Login data-load model: runs the real loadAllFinancialData() from an
// index.html against a fake Supabase with simulated round-trip latency, shared
// bandwidth and server time. Same synthetic dataset for every version.
// Usage: node perf/startup-network-model.cjs <index.html> [rttMs] [mbps] [snapshotDbMs] [cold|warm]
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const [file,rttArg,mbpsArg,snapArg,modeArg]=process.argv.slice(2);
const RTT=Number(rttArg||250),MBPS=Number(mbpsArg||5),SNAPSHOT_DB_MS=Number(snapArg||800),MODE=modeArg||'cold';
// Real time: browser CPU work (rendering, calculations) is not rescaled.
const SCALE=Number(process.env.MODEL_SCALE||1);
const BYTES_PER_MS=MBPS*1e6/8/1000, COMPRESSION=0.22, DB_MS=20;
const html=fs.readFileSync(file,'utf8');
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const boot=code.slice(0,code.indexOf('(async function boot(){'));

// Dataset sizes follow the repository's existing performance fixtures.
const sizes={pb_groups:150,pb_staff:40,pb_members:1700,pb_loans:2900,pb_inventory:200,pb_orders:3000,
  pb_savings:45000,pb_repayments:31000,pb_excess_payments:7800,pb_guarantors:1700,pb_meetings:6000,
  pb_suppliers:20,pb_purchases:300,pb_purchase_lines:900,pb_reconciliations:500,pb_expenses:500};
const pad=n=>String(n).padStart(12,'0');
const data={};
for(const [t,n] of Object.entries(sizes)){
  data[t]=Array.from({length:n},(_,i)=>({id:`00000000-0000-4000-8000-${pad(i)}`,business_id:'biz',status:'approved',
    amount:100,principal:80,interest:20,member_id:'m'+(i%1700),loan_id:'l'+(i%2900),group_id:'g'+(i%150),
    recorded_by:'o'+(i%40),meeting_date:'2026-10-01',created_at:'2026-10-01T08:00:00Z',updated_at:'2026-10-01T08:00:00Z',
    notes:null,edit_notes:null,voided_at:null,meeting_id:'mt'+(i%6000)}));
}
const rowBytes=JSON.stringify(data.pb_repayments[0]).length;
let linkFreeAt=0,requests=0,bytes=0;
const t0=Date.now(),now=()=>(Date.now()-t0)/SCALE;
const wait=ms=>new Promise(r=>setTimeout(r,ms*SCALE));
async function network(responseBytes,dbMs){
  requests++;bytes+=responseBytes;
  await wait(RTT/2+dbMs);
  const start=Math.max(now(),linkFreeAt);const transfer=responseBytes*COMPRESSION/BYTES_PER_MS;
  linkFreeAt=start+transfer;
  await wait(linkFreeAt-now()+RTT/2);
}
function query(table){
  const q={filters:[],limitN:null,from:null,to:null,gtId:null,gte:null,head:false};
  const api={select(){return api},order(){return api},eq(c,v){if(c==='status')q.status=v;return api},
    limit(n){q.limitN=n;return api},range(a,b){q.from=a;q.to=b;return api},gt(c,v){q.gtId=v;return api},
    gte(c,v){q.gte=v;return api},in(c,v){q.inIds=v;return api},maybeSingle(){q.single=true;return api},
    then(resolve,reject){return run().then(resolve,reject)}};
  async function run(){
    let rows=data[table]||[];
    if(q.status) rows=rows.filter(r=>r.status===q.status);
    if(q.gte) rows=rows.filter(r=>r.updated_at>=q.gte);
    if(q.inIds) rows=rows.filter(r=>q.inIds.includes(r.id));
    let offsetScan=0;
    if(q.gtId) rows=rows.filter(r=>r.id>q.gtId);
    if(q.from!==null){offsetScan=q.from;rows=rows.slice(q.from,q.to+1);} else if(q.limitN) rows=rows.slice(0,q.limitN);
    if(q.single) rows=rows.slice(0,1);
    // Server time: fixed per-request cost plus rows read. OFFSET must read
    // and discard every earlier row (measured separately with PGlite).
    await network(rows.length*rowBytes+200, DB_MS+(rows.length+offsetScan)*0.002);
    return {data:q.single?(rows[0]||null):rows,error:null};
  }
  return api;
}
const sb={auth:{onAuthStateChange(){},getSession:async()=>({data:{session:{user:{id:'auth'}}},error:null})},
  from:query,
  rpc(name){
    const p=(async()=>{
      if(name==='pb_financial_snapshot'){
        await network(60000,SNAPSHOT_DB_MS);
        return {data:{version:1,authorized:true,asOfDate:vm.runInContext('todayISO()',sandbox),complete:true,checkedAt:new Date().toISOString(),rows:[],visibleLoanIds:data.pb_loans.map(r=>r.id)},error:null};
      }
      if(name==='pb_cash_collection_totals'){
        await network(4000,150);return {data:{authorized:true,rows:[]},error:null};
      }
      await network(500,DB_MS);return {data:null,error:null};
    })();
    p.abortSignal=()=>p;return p;
  },
  channel(){return {on(){return this},subscribe(){}}},removeChannel(){}};
const page={innerHTML:'',style:{},classList:{toggle(){},add(){},remove(){}}},elements=new Map();
const sandbox={WamamaFinance:require('../financial-rules.js'),console,Intl,Date,URL,Map,Set,Promise,JSON,Math,
  crypto:require('node:crypto').webcrypto,window:{addEventListener(){}},
  document:{addEventListener(){},getElementById(id){
    if(id==='page') return page;
    if(!elements.has(id)) elements.set(id,{innerHTML:'',textContent:'',value:'',style:{},classList:{toggle(){},add(){},remove(){}}});
    return elements.get(id);
  },querySelector(){return null},documentElement:page},
  navigator:{onLine:true},localStorage:{getItem(){return null},setItem(){},removeItem(){},key(){},length:0},
  sessionStorage:{getItem(){return null},setItem(){},removeItem(){}},
  setTimeout,clearTimeout,setInterval(){},requestAnimationFrame(){},AbortController,supabase:{createClient(){return sb}}};
vm.createContext(sandbox);vm.runInContext(boot,sandbox);
const marks={};
sandbox.__mark=name=>{if(!(name in marks))marks[name]=Math.round(now())};
const cacheTime=Date.now()-60*60*1000;
sandbox.__cached=MODE==='warm'?Object.fromEntries(Object.entries(data).map(([t,rows])=>[t,{rows,fullSyncAt:Date.now()-60000,reconciledAt:Date.now(),savedAt:cacheTime}])):{};
vm.runInContext(`
state.staff={id:'admin',role:'admin',app_role:'admin',business_id:'biz'};state.session={user:{id:'auth'}};state.settings={};
readFinancialCache=async table=>__cached[table]||null;writeFinancialCache=async()=>{};persistPartialFinancialCache=async()=>{};
loadInventoryReferencePrices=async()=>true;releaseDuePrepaymentsInBackground=()=>{};cacheDataKey=()=>{};
refreshOfficerLoanDepositBalances=async()=>true;
render=()=>{
  if(state.loading!==false) return;
  __mark('firstUseful');
  // Render the real dashboard and record what it actually shows.
  try{ pageDashboard(); }catch(e){ __mark('renderError:'+e.message); }
  const html=String(document.getElementById('page').innerHTML||'');
  if(html.includes('provisional-figures-notice')) __mark('serverFigures');
  else if(html.includes('Operational overview')) { __mark('serverFigures'); __mark('verified'); }
};
scheduleRealtimeRender=()=>render();
`,sandbox);
(async()=>{
  await vm.runInContext('loadAllFinancialData()',sandbox);
  sandbox.__mark('allTablesLoaded');
  if(process.env.MODEL_DEBUG) console.error(String(page.innerHTML).replace(/\s+/g,' ').slice(0,300));
  if(!('verified' in marks) && vm.runInContext('state._portfolioDataVerified',sandbox)) marks.verified=marks.allTablesLoaded;
  console.log(JSON.stringify({file:path.basename(path.dirname(file))+'/'+path.basename(file),mode:MODE,rttMs:RTT,mbps:MBPS,snapshotDbMs:SNAPSHOT_DB_MS,
    firstUsefulMs:marks.firstUseful??null,serverFiguresMs:marks.serverFigures??null,verifiedMs:marks.verified??null,
    errors:Object.keys(marks).filter(k=>k.startsWith('renderError')),allTablesMs:marks.allTablesLoaded,requests,
    uncompressedMB:+(bytes/1e6).toFixed(1),approxTransferMB:+(bytes*COMPRESSION/1e6).toFixed(1)}));
  process.exit(0);
})().catch(e=>{console.error(e);process.exit(1);});
