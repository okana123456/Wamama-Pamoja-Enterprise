// Server-first dashboard: figures that come from server functions appear before
// the savings/repayment history; savings-based figures never show a number
// (and never zero) until the ledger is verified; verification does not change
// the server-sourced figures.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const elements=new Map(),el=id=>{if(!elements.has(id))elements.set(id,{innerHTML:'',textContent:'',value:'',style:{},classList:{toggle(){},add(){},remove(){}}});return elements.get(id);};
const rpcCalls=[];let cashResponse={data:{authorized:true,rows:[{recordedBy:'o1',groupId:'g1',amount:500,interest:100,entries:2}]},error:null};
const sb={auth:{onAuthStateChange(){}},rpc(name,args){rpcCalls.push(name);const p=Promise.resolve(name==='pb_cash_collection_totals'?cashResponse:{data:null,error:null});p.abortSignal=()=>p;return p;}};
const sandbox={WamamaFinance:require('../financial-rules.js'),console,Intl,Date,URL,Map,Set,Promise,JSON,Math,
  window:{addEventListener(){}},document:{addEventListener(){},getElementById:el,querySelector(){return null},documentElement:el('root')},
  navigator:{onLine:true},localStorage:{getItem(){return null},setItem(){},removeItem(){}},sessionStorage:{getItem(){return null},setItem(){},removeItem(){}},
  setTimeout,clearTimeout,setInterval(){},requestAnimationFrame(){},AbortController,supabase:{createClient(){return sb}}};
vm.createContext(sandbox);vm.runInContext(code.slice(0,code.indexOf('(async function boot(){')),sandbox);
const run=s=>vm.runInContext(s,sandbox);
const page=()=>String(el('page').innerHTML);
const flush=()=>new Promise(r=>setTimeout(r,5));
(async()=>{
run(`scheduleRealtimeRender=()=>{};persistPartialFinancialCache=async()=>{};
state.staff={id:'admin',role:'admin',app_role:'admin',business_id:'biz'};state.settings={savings_threshold:400};state.view='dashboard';
state.data.staff=[{id:'o1',role:'loan_officer',status:'active',full_name:'Officer One'}];
state.data.groups=[{id:'g1',name:'Group',officer_id:'o1',status:'active'}];
state.data.members=[{id:'m1',group_id:'g1',full_name:'Client',status:'active'},{id:'m2',group_id:'g1',full_name:'Client 2',status:'active'}];
state.data.loans=[{id:'l1',member_id:'m1',group_id:'g1',status:'active',loan_value:800,total_payable:1000,weekly_installment:100,start_date:'2026-10-01'},
                  {id:'l2',member_id:'m2',group_id:'g1',status:'active',loan_value:800,total_payable:1000,weekly_installment:100,start_date:'2026-10-01'}];
state.data.savings=[];state.data.repayments=[];state.data.excessPayments=[];state.data.orders=[];state.data.inventory=[];
state._portfolioDataVerified=false;state._portfolioRefreshFailed=false;state.loading=false;_dashFilter='month';`);
const snapshot=run(`({version:1,authorized:true,complete:true,asOfDate:todayISO(),checkedAt:new Date().toISOString(),
  visibleLoanIds:['l1','l2'],rows:[
   {id:'l1',group_id:'g1',officer_id:'o1',status:'active',start_date:'2026-10-01',weekly_installment:100,loan_value:800,total_payable:1000,paid:300,principalPaid:240,interestPaid:60,outstandingPI:700,outstandingPrincipal:560,arrears:0,nextDueDate:'2026-11-26',repaymentCount:3,repaymentUpdatedAt:null},
   {id:'l2',group_id:'g1',officer_id:'o1',status:'active',start_date:'2026-10-01',weekly_installment:100,loan_value:800,total_payable:1000,paid:100,principalPaid:80,interestPaid:20,outstandingPI:900,outstandingPrincipal:720,arrears:200,nextDueDate:'2026-11-19',repaymentCount:1,repaymentUpdatedAt:null}]})`);

// 1. Before any server figures: a loading message, never zero totals.
run('pageDashboard()');
assert.match(page(),/Updating financial figures/);
assert.doesNotMatch(page(),/KES\s*0/);

// 2. Incomplete local loan list: provisional figures refused.
sandbox.__partial={...snapshot,visibleLoanIds:['l1','l2','l3']};
assert.equal(run('applyProvisionalFinancialSnapshot(__partial)'),false,'missing visible loan blocks provisional totals');
assert.equal(run('dashboardShowsProvisionalFigures()'),false);
sandbox.__wrongDay={...snapshot,asOfDate:'2000-01-01'};
assert.equal(run('applyProvisionalFinancialSnapshot(__wrongDay)'),false,'stale snapshot refused');

// 3. Provisional: server balances and collections shown, savings "Verifying…".
sandbox.__snap=snapshot;
assert.equal(run('applyProvisionalFinancialSnapshot(__snap)'),true);
run('pageDashboard()');
assert.match(page(),/Updating collection totals/,'waits for server collection totals');
await flush();
run('pageDashboard()');
const provisionalHtml=page();
assert.match(provisionalHtml,/provisional-figures-notice/);
assert.match(provisionalHtml,/Outstanding P \+ I<\/div><div class="v">KES\s*1,600/);
assert.match(provisionalHtml,/Repayments received<\/div><div class="v">KES\s*500/);
assert.match(provisionalHtml,/Savings collected<\/div><div class="v"><span class="muted"[^>]*>Verifying…/);
assert.doesNotMatch(provisionalHtml,/Savings collected<\/div><div class="v">KES/,'no savings number before verification');
assert.equal(run('state._portfolioDataVerified'),false,'provisional is not verified');
// Other financial pages keep waiting for verified figures.
run(`state.view='arrears';pageArrears()`);assert.match(page(),/Updating financial figures/);
run(`state.view='dashboard'`);

// Officer dashboard in provisional mode.
run(`state._dashboardOfficerFilter='o1';pageDashboard()`);await flush();run('pageDashboard()');
assert.match(page(),/Savings recorded<\/div><div class="v"><span class="muted"[^>]*>Verifying…/);
assert.match(page(),/provisional-figures-notice/);
run(`state._dashboardOfficerFilter=''`);

// 4. Verification with the same server snapshot: savings appear, server
// figures unchanged, collection totals kept (no "Updating" flash).
run(`state.data.savings=[{id:'s1',member_id:'m1',group_id:'g1',recorded_by:'o1',amount:250,status:'approved',meeting_date:todayISO()}];
state.data.repayments=[
 {id:'r1',loan_id:'l1',member_id:'m1',amount:100,principal:80,interest:20,status:'approved',meeting_date:'2026-10-08'},
 {id:'r2',loan_id:'l1',member_id:'m1',amount:100,principal:80,interest:20,status:'approved',meeting_date:'2026-10-15'},
 {id:'r3',loan_id:'l1',member_id:'m1',amount:100,principal:80,interest:20,status:'approved',meeting_date:'2026-10-22'},
 {id:'r4',loan_id:'l2',member_id:'m2',amount:100,principal:80,interest:20,status:'approved',meeting_date:'2026-10-08'}];`);
const cashCallsBefore=rpcCalls.filter(n=>n==='pb_cash_collection_totals').length;
sandbox.__prefetched={epoch:run('state._accountEpoch'),staffId:'admin',request:Promise.resolve({data:snapshot,error:null})};
assert.equal(await run('refreshFinancialSnapshot(null,{prefetched:__prefetched})'),true);
run('state._portfolioDataVerified=true');
run('pageDashboard()');
const verifiedHtml=page();
assert.doesNotMatch(verifiedHtml,/provisional-figures-notice/);
assert.doesNotMatch(verifiedHtml,/Updating collection totals/,'cash totals kept across verification');
assert.equal(rpcCalls.filter(n=>n==='pb_cash_collection_totals').length,cashCallsBefore);
assert.match(verifiedHtml,/Savings collected<\/div><div class="v">KES\s*250/);
for(const label of ['Outstanding P \\+ I','Repayments received','Outstanding principal']){
  const pick=h=>h.match(new RegExp(label+'<\\/div><div class="v">([^<]*)'))[1];
  assert.equal(pick(verifiedHtml),pick(provisionalHtml),`${label} unchanged by verification`);
}

// 5. Failed server collection totals: an explicit retry state, not zeros.
run(`resetAccountData();state.staff={id:'admin',role:'admin',app_role:'admin',business_id:'biz'};state.loading=false;
state.data.loans=[{id:'l1',member_id:'m1',group_id:'g1',status:'active'},{id:'l2',member_id:'m2',group_id:'g1',status:'active'}];
state.data.groups=[{id:'g1',name:'Group',officer_id:'o1',status:'active'}];`);
assert.equal(run('state._provisionalFigures'),false,'account change clears provisional figures');
cashResponse={data:null,error:{message:'timeout'}};
sandbox.__snap2={...snapshot,checkedAt:new Date().toISOString()};
assert.equal(run('applyProvisionalFinancialSnapshot(__snap2)'),true);
run('pageDashboard()');await flush();run('pageDashboard()');
assert.match(page(),/Unable to update financial figures/);
assert.match(page(),/Try again/);
assert.doesNotMatch(page(),/KES\s*0/);
console.log('PASS: loading, incomplete/stale refusal, provisional admin+officer, verified consistency, failure state, account reset');
})().catch(e=>{console.error(e);process.exit(1);});
