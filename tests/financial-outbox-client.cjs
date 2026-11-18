// Browser outbox behaviour against an idempotent fake server.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const boot=code.slice(0,code.indexOf('(async function boot(){'));

// Shared device storage (all tabs of one browser share localStorage).
const store=new Map();
const localStorage={getItem:k=>store.has(k)?store.get(k):null,setItem:(k,v)=>store.set(k,String(v)),removeItem:k=>store.delete(k),
  key:i=>[...store.keys()][i],get length(){return store.size}};
// Fake server implementing the pb_submit_meeting contract.
const server={rows:new Map(),requests:0,loseNextResponse:false,failLoan:null,delay:20,
  async submit(staff,p){
    this.requests++;
    await new Promise(r=>setTimeout(r,this.delay));
    const out={version:1,operation_id:p.operation_id,meeting:{state:'existing',row:{id:'meeting-'+p.group_id+p.meeting_date,group_id:p.group_id,meeting_date:p.meeting_date}},savings:[],repayments:[]};
    const record=(kind,item,extra)=>{
      const key=staff.business_id+':'+item.client_operation_id;
      if(kind==='repayments' && item.loan_id===this.failLoan) return {state:'failed',message:'The selected active loan was not found in your business.',client_operation_id:item.client_operation_id};
      if(this.rows.has(key)){
        const row=this.rows.get(key);
        if(row.amount!==item.amount) return {state:'failed',message:'OPERATION_MISMATCH',client_operation_id:item.client_operation_id};
        return {state:'existing',row,client_operation_id:item.client_operation_id};
      }
      const row={id:'row-'+this.rows.size,amount:item.amount,...extra};
      this.rows.set(key,row);
      return {state:'created',row,client_operation_id:item.client_operation_id};
    };
    p.savings.forEach(i=>out.savings.push(record('savings',i,{member_id:i.member_id})));
    p.repayments.forEach(i=>out.repayments.push(record('repayments',i,{loan_id:i.loan_id})));
    if(this.loseNextResponse){ this.loseNextResponse=false; throw new TypeError('Failed to fetch'); }
    return out;
  }};

function openTab(staff){
  const toasts=[],page={innerHTML:'',style:{},classList:{toggle(){},add(){},remove(){}}};
  const sb={auth:{onAuthStateChange(){},getSession:async()=>({data:{session:{user:{id:'u'}}}})},
    rpc(name,args){
      const run=async()=>{
        if(name!=='pb_submit_meeting') return {data:null,error:{message:'unexpected '+name}};
        try{ return {data:await server.submit(staff,args.p_payload),error:null}; }
        catch(e){ return {data:null,error:{message:e.message}}; }
      };
      const p=run(); p.abortSignal=()=>p; return p;
    },
    from(){ return {insert(){return Promise.resolve({})}}; }};
  const sandbox={WamamaFinance:require('../financial-rules.js'),console,Intl,Date,URL,Map,Set,Promise,JSON,Math,
    crypto:require('node:crypto').webcrypto,TextEncoder,Uint8Array,
    window:{addEventListener(){},crypto:require('node:crypto').webcrypto},
    document:{addEventListener(){},getElementById(){return page},querySelector(){return null},documentElement:page},
    navigator:{onLine:true},localStorage,sessionStorage:{getItem(){return null},setItem(){},removeItem(){}},
    setTimeout,clearTimeout,setInterval(){},requestAnimationFrame(){},AbortController,
    supabase:{createClient(){return sb}}};
  vm.createContext(sandbox);vm.runInContext(boot,sandbox);
  const run=s=>vm.runInContext(s,sandbox);
  sandbox.__toasts=toasts;sandbox.__staff=staff;
  run(`toast=(m,k)=>__toasts.push([k,m]);render=()=>{};renderMeetList=()=>{};renderOutboxStatus=()=>{};audit=()=>{};
    refreshExcessRelatedData=async()=>{};closeFullyPaidLoans=async()=>0;persistPartialFinancialCache=async()=>{};
    scheduleFinancialSnapshotRefresh=()=>{};invalidateCollectionComplianceCache=()=>{};confirmDialog=(m,fn)=>fn();
    state.staff=__staff;state.session={};
    state.data.members=[{id:'m1',group_id:'g1',status:'active'},{id:'m2',group_id:'g1',status:'active'},{id:'m1',group_id:'g1',status:'active'}];
    state.data.loans=[{id:'l1',member_id:'m1',status:'active'},{id:'l2',member_id:'m2',status:'active'}];
    state.data.groups=[{id:'g1',name:'Group'}];`);
  return {run,toasts,sandbox};
}
const fill=tab=>tab.run(`state._meet={groupId:'g1',date:'2026-11-17',entries:{m1:{savings:'100',repayments:{l1:200}},m2:{savings:'50',repayments:{l2:100}}}}`);
const tick=ms=>new Promise(r=>setTimeout(r,ms));
const A={id:'staffA',business_id:'biz1'},B={id:'staffB',business_id:'biz1'};

(async()=>{
  // 1. Double click / concurrent submits: one request, one copy of each entry.
  let tab=openTab(A);fill(tab);
  await Promise.all([tab.run('submitMeeting()'),tab.run('submitMeeting()'),tab.run('submitMeeting()')]);
  assert.equal(server.requests,1,'one request for three clicks');
  assert.equal(server.rows.size,4,'duplicated member list still yields one saving per member');
  assert.equal(tab.run('readOutbox().length'),0,'confirmed submission leaves the device');
  assert.equal(tab.run('state._meet.groupId'),'','form cleared after storing');

  // 2. Server saves but the response is lost: kept with the same IDs; resend
  //    returns existing rows and creates nothing.
  server.rows.clear();server.requests=0;server.loseNextResponse=true;fill(tab);
  await tab.run('submitMeeting()');
  assert.equal(server.rows.size,4);
  assert.equal(tab.run('readOutbox().length'),1,'unconfirmed submission kept on device');
  assert.equal(tab.run('readOutbox()[0].status'),'pending');
  // Re-entering the same meeting while it is pending is blocked.
  fill(tab);await tab.run('submitMeeting()');
  assert.equal(server.requests,1,'no new submission while one is pending for the meeting');
  tab.run(`state._meet={groupId:'',date:'2026-11-17',entries:{}}`);

  // 3. Reload: a fresh tab with the same storage resends the same IDs.
  const ids=JSON.stringify(tab.run('readOutbox()[0].payload'));
  tab=openTab(A);
  assert.equal(JSON.stringify(tab.run('readOutbox()[0].payload')),ids,'IDs survive reload unchanged');
  // 4. Overlapping flushes in one tab and in a second tab.
  const tab2=openTab(A);
  await Promise.all([tab.run('flushOutbox()'),tab.run('flushOutbox()'),tab2.run('flushOutbox()'),tab2.run('flushOutbox()')]);
  assert.equal(server.rows.size,4,'no duplicates from overlapping flushes or tabs');
  assert.ok(server.requests<=3,'overlapping flushes coalesce');
  assert.equal(tab.run('readOutbox().length'),0);

  // 5. Partial success: one loan fails; only that entry is re-sent later.
  server.rows.clear();server.requests=0;server.failLoan='l2';fill(tab);
  await tab.run('submitMeeting()');
  assert.equal(server.rows.size,3);
  assert.equal(tab.run('readOutbox()[0].status'),'needs_attention');
  server.failLoan=null;
  const before=server.requests;
  await tab.run(`retryOutboxEntry(readOutbox()[0].id)`);
  assert.equal(server.requests,before+1);
  assert.equal(server.rows.size,4,'only the failed entry was added');
  assert.equal(tab.run('readOutbox().length'),0);

  // 6. Offline: stored, nothing sent; on reconnection it is sent once.
  server.rows.clear();server.requests=0;tab.sandbox.navigator.onLine=false;fill(tab);
  await tab.run('submitMeeting()');
  assert.equal(server.requests,0);assert.equal(tab.run('readOutbox().length'),1);
  tab.sandbox.navigator.onLine=true;
  await Promise.all([tab.run('flushOutbox()'),tab.run('flushOutbox()')]);
  assert.equal(server.rows.size,4);assert.equal(tab.run('readOutbox().length'),0);

  // 7. Account switching: another staff member never sees or sends A's entries.
  tab.sandbox.navigator.onLine=false;fill(tab);await tab.run('submitMeeting()');
  const tabB=openTab(B);
  assert.equal(tabB.run('readOutbox().length'),0,'outbox is per staff account');
  tabB.sandbox.navigator.onLine=true;await tabB.run('flushOutbox()');
  assert.equal(tab.run('readOutbox().length'),1,"B's flush leaves A's entry untouched");
  tab.run('resetAccountData()');
  assert.equal(tab.run('state._meet'),null,'meeting draft cleared on account change');

  // 8. Pre-update queue entries are moved to review and never sent automatically.
  store.set('pb_pb_default_queue',JSON.stringify([{table:'pb_savings',row:{recorded_by:'staffB',group_id:'g1',meeting_date:'2026-11-10',member_id:'m1',amount:100},t:1}]));
  server.requests=0;
  assert.equal(tabB.run('adoptLegacyQueue()'),1);
  assert.equal(tabB.run('readOutbox()[0].status'),'needs_attention');
  await tabB.run('flushOutbox()');
  assert.equal(server.requests,0,'legacy entries need a person to confirm');
  assert.equal(store.has('pb_pb_default_queue'),false);

  console.log('PASS: double clicks, lost response, reload, overlapping flushes, two tabs, partial batch, offline, account switch, legacy queue');
})().catch(e=>{console.error(e);process.exit(1);});
