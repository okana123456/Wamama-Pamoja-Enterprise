// Login data-load model: runs the real loadAllFinancialData() and dashboard
// from an index.html against a fake Supabase with simulated round-trip
// latency, shared bandwidth and server time. Row counts are the production
// counts reported by wamama-production-safeguards-check.sql (18 Nov 2026);
// row sizes are estimates. Reports timings and bytes downloaded (egress).
//
// Usage: node perf/startup-network-model.cjs <index.html> [rttMs] [mbps] [snapshotDbMs] [mode]
//   mode: cold    – new device, nothing cached
//         reload  – same device, cache 30 min old, today's snapshot saved
//         later   – same device, cache 3 h old, today's snapshot saved
//         nextday – same device, cache 18 h old, yesterday's snapshot
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const [file,rttArg,mbpsArg,snapArg,modeArg]=process.argv.slice(2);
const RTT=Number(rttArg||250),MBPS=Number(mbpsArg||5),SNAPSHOT_DB_MS=Number(snapArg||800),MODE=modeArg||'cold';
// Real time: browser CPU work (rendering, calculations) is not rescaled.
const SCALE=Number(process.env.MODEL_SCALE||1);
const BYTES_PER_MS=MBPS*1e6/8/1000, COMPRESSION=0.22, DB_MS=20;
const html=fs.readFileSync(file,'utf8');
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const boot=code.slice(0,code.indexOf('(async function boot(){'));

const sizes={pb_groups:219,pb_staff:15,pb_members:1944,pb_loans:3631,pb_inventory:498,pb_orders:3932,
  pb_savings:33473,pb_repayments:52978,pb_excess_payments:15721,pb_guarantors:1875,pb_meetings:4172,
  pb_suppliers:2,pb_purchases:43,pb_purchase_lines:43,pb_reconciliations:1,pb_expenses:9};
// Estimated JSON bytes per row as returned by select('*').
const width={pb_repayments:560,pb_savings:330,pb_excess_payments:480,pb_loans:690,pb_orders:540,pb_members:480,
  pb_meetings:220,pb_guarantors:220,pb_inventory:300,pb_groups:400,pb_staff:600};
const ID_ONLY_BYTES=47,SNAPSHOT_ROW_BYTES=450,ID_LIST_BYTES=39;
const MIN=60*1000,HOUR=60*MIN;
const cacheAge={cold:0,reload:30*MIN,later:3*HOUR,nextday:18*HOUR}[MODE];
const recent=new Date(Date.now()-10*MIN).toISOString(),old='2026-10-01T08:00:00Z';
const pad=n=>String(n).padStart(12,'0');
const data={};
for(const [t,n] of Object.entries(sizes)){
  data[t]=Array.from({length:n},(_,i)=>({id:`00000000-0000-4000-8000-${pad(i)}`,business_id:'biz',status:'approved',
    amount:100,principal:80,interest:20,member_id:'m'+(i%1944),loan_id:'l'+(i%3631),group_id:'g'+(i%219),
    recorded_by:'o'+(i%15),meeting_date:'2026-10-01',created_at:old,
    // About 1% of rows changed in the last few minutes.
    updated_at:i%100===0?recent:old,notes:null,edit_notes:null,voided_at:null,meeting_id:'mt'+(i%4172)}));
}
let linkFreeAt=0,requests=0,bytes=0;const byKind={};
const t0=Date.now(),now=()=>(Date.now()-t0)/SCALE;
const wait=ms=>new Promise(r=>setTimeout(r,ms*SCALE));
async function network(kind,responseBytes,dbMs){
  requests++;bytes+=responseBytes;byKind[kind]=(byKind[kind]||0)+responseBytes;
  await wait(RTT/2+dbMs);
  const start=Math.max(now(),linkFreeAt);const transfer=responseBytes*COMPRESSION/BYTES_PER_MS;
  linkFreeAt=start+transfer;
  await wait(linkFreeAt-now()+RTT/2);
}
function query(table){
  const q={limitN:null,from:null,to:null,gtId:null,gte:null,cols:'*'};
  const api={select(c){q.cols=c||'*';return api},order(){return api},eq(c,v){if(c==='status')q.status=v;return api},
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
    const per=q.cols==='id'?ID_ONLY_BYTES:(width[table]||300);
    const kind=q.cols==='id'?'idOnly':q.status==='pending'?'pending':q.gte?'changedRows':'fullTable';
    await network(kind,rows.length*per+200, DB_MS+(rows.length+offsetScan)*0.002);
    return {data:q.single?(rows[0]||null):rows,error:null};
  }
  return api;
}
const allLoanIds=data.pb_loans.map(r=>r.id);
function snapshotResponse(args,v2){
  const since=args?.p_since,ids=args?.p_loan_ids;
  const rows=ids?ids.length:since?Math.ceil(allLoanIds.length*0.02):allLoanIds.length;
  const includeIds=!v2 || args.p_include_ids!==false;
  const bytesOut=rows*SNAPSHOT_ROW_BYTES+(includeIds?allLoanIds.length*ID_LIST_BYTES:0)+300;
  const pick=ids?ids:since?allLoanIds.slice(0,rows):allLoanIds;
  const body={version:1,authorized:true,asOfDate:vm.runInContext('todayISO()',sandbox),complete:!ids&&!since,
    checkedAt:new Date().toISOString(),rows:pick.map(id=>({id,status:'active',paid:0,principalPaid:0,interestPaid:0,repaymentCount:0,outstandingPI:0,outstandingPrincipal:0,arrears:0})),
    ...(includeIds?{visibleLoanIds:allLoanIds}:{})};
  if(v2) Object.assign(body,{visibleLoanIdsHash:'h1',visibleLoanCount:allLoanIds.length,includesVisibleLoanIds:includeIds});
  return {bytesOut,body};
}
const sb={auth:{onAuthStateChange(){},getSession:async()=>({data:{session:{user:{id:'auth'}}},error:null})},
  from:query,
  rpc(name,args){
    const p=(async()=>{
      if(name==='pb_financial_snapshot' || name==='pb_financial_snapshot_v2'){
        const {bytesOut,body}=snapshotResponse(args,name.endsWith('_v2'));
        await network('snapshot',bytesOut,SNAPSHOT_DB_MS);
        return {data:body,error:null};
      }
      if(name==='pb_cash_collection_totals'){
        await network('cashTotals',4000,150);return {data:{authorized:true,rows:[]},error:null};
      }
      await network('otherRpc',500,DB_MS);return {data:null,error:null};
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
const cachedAt=Date.now()-cacheAge;
sandbox.__cached=MODE==='cold'?{}:Object.fromEntries(Object.entries(data).map(([t,rows])=>[t,{rows,fullSyncAt:cachedAt,reconciledAt:cachedAt,savedAt:cachedAt}]));
// Today's snapshot saved on the device (not usable the next day).
sandbox.__snapshotBase=['reload','later'].includes(MODE)?{asOfDate:vm.runInContext('todayISO()',sandbox),checkedAt:new Date(cachedAt).toISOString(),
  visibleIds:allLoanIds,visibleHash:'h1',byLoan:new Map(allLoanIds.map(id=>[id,{id,status:'active',paid:0,principalPaid:0,interestPaid:0,repaymentCount:0,outstandingPI:0,outstandingPrincipal:0,arrears:0}]))}:null;
vm.runInContext(`
state.staff={id:'admin',role:'admin',app_role:'admin',business_id:'biz'};state.session={user:{id:'auth'}};state.settings={};
readFinancialCache=async table=>__cached[table]||null;writeFinancialCache=async()=>{};persistPartialFinancialCache=async()=>{};
if(typeof readSnapshotCache==='function'){readSnapshotCache=async()=>__snapshotBase;writeSnapshotCache=async()=>{};}
loadInventoryReferencePrices=async()=>true;releaseDuePrepaymentsInBackground=()=>{};cacheDataKey=()=>{};
refreshOfficerLoanDepositBalances=async()=>true;
render=()=>{
  if(state.loading!==false) return;
  __mark('firstUseful');
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
  if(!('verified' in marks) && vm.runInContext('state._portfolioDataVerified',sandbox)) marks.verified=marks.allTablesLoaded;
  const kb=n=>Math.round(n/1000);
  console.log(JSON.stringify({file:path.basename(path.dirname(file))+'/'+path.basename(file),mode:MODE,rttMs:RTT,mbps:MBPS,
    serverFiguresMs:marks.serverFigures??null,verifiedMs:marks.verified??null,
    errors:Object.keys(marks).filter(k=>k.startsWith('renderError')),requests,
    downloadedKB:kb(bytes),compressedKB:kb(bytes*COMPRESSION),
    byKindKB:Object.fromEntries(Object.entries(byKind).map(([k,v])=>[k,kb(v)]))}));
  process.exit(0);
})().catch(e=>{console.error(e);process.exit(1);});
