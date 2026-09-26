const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const rules=require('../financial-rules.js');
const loan={id:'loan-a',loan_value:800,total_payable:1000,weekly_installment:100,start_date:'2026-09-17'};
const payment=(id,date,amount,extra={})=>({id,loan_id:loan.id,meeting_date:date,amount,principal:amount*.8,interest:amount*.2,status:'approved',...extra});
assert.equal(rules.metrics(loan,[],'2026-09-17').arrears,0,'first due day remains payable');
assert.equal(rules.metrics(loan,[],'2026-09-18').arrears,95);
assert.equal(rules.metrics(loan,[payment('p','2026-09-17',100)],'2026-09-24').arrears,0,'second due day is not overdue');
assert.equal(rules.metrics(loan,[payment('p','2026-09-17',100)],'2026-09-25').arrears,95);
assert.equal(rules.metrics(loan,[payment('p','2026-09-17',98)],'2026-09-18').arrears,0,'existing KES 5 tolerance');
assert.equal(rules.metrics(loan,[],'2026-09-16').nextDueDate,'2026-09-17');
assert.equal(rules.metrics(loan,[],'2026-09-17').nextDueDate,'2026-09-17','first due date must appear in Due Today');
const payments=[payment('valid','2026-09-17',100),payment('void','2026-09-17',900,{voided_at:'2026-09-18'}),payment('pending','2026-09-17',200,{status:'pending'}),payment('rejected','2026-09-17',300,{status:'rejected'}),payment('future','2026-10-01',400)];
assert.equal(rules.metrics(loan,payments,'2026-09-25').paid,100);
assert.equal(rules.metrics(loan,payments,'2026-09-25').outstandingPI,900);
assert.equal(rules.metrics(loan,[payment('all','2026-09-17',1000)],'2026-09-25').nextDueDate,null);
assert.equal(rules.metrics({...loan,start_date:null},[],'2026-09-25').arrears,0);
assert.equal(rules.paymentDate({created_at:'2026-09-16T22:30:00Z'}),'2026-09-17','Kenya midnight');

const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
new vm.Script(code); // Check the complete production script, including startup.
const node={innerHTML:'',appendChild(){},insertAdjacentHTML(){},style:{},classList:{toggle(){},add(){},remove(){}}};
const sandbox={WamamaFinance:rules,console,Intl,Date,URL,Map,Set,Promise,
  window:{addEventListener(){}},document:{addEventListener(){},getElementById(){return node},querySelector(){return null},documentElement:node},
  navigator:{onLine:true},localStorage:{getItem(){return null},setItem(){},removeItem(){}},sessionStorage:{getItem(){return null},setItem(){},removeItem(){}},
  setInterval(){},setTimeout(){return 1},clearTimeout(){},requestAnimationFrame(){},
  supabase:{createClient(){return {auth:{onAuthStateChange(){}}}}}};
vm.createContext(sandbox);
vm.runInContext(code.slice(0,code.indexOf('(async function boot(){')).replace('const todayISO = () => kenyaDateISO(new Date());',"const todayISO = () => '2026-09-25';"),sandbox);
function run(script){return vm.runInContext(script,sandbox);}
sandbox.fixtureLoan=loan;sandbox.fixturePayments=payments;
run(`state.staff={id:'owner-new',role:'admin',app_role:'admin',business_id:'biz'};
 state.data.staff=[{id:'owner-old',role:'loan_officer',full_name:'Old',status:'active'},{id:'owner-new',role:'loan_officer',full_name:'New',status:'active'}];
 state.data.members=[{id:'member',group_id:'group-new'}];
 state.data.groups=[{id:'group-old',officer_id:'owner-old'},{id:'group-new',officer_id:'owner-new'}];
 state.data.loans=[{...fixtureLoan,member_id:'member',group_id:'group-old',officer_id:'owner-old',status:'active'}];
 state.data.repayments=fixturePayments;
 state._portfolioDataVerified=true;`);
assert.equal(run(`buildArrearsRows({portfolioView:true,dateRange:{start:'2000-01-01',end:'2999-12-31'},officerFilter:'owner-old'}).length`),0);
const admin=run(`buildArrearsRows({portfolioView:true,dateRange:{start:'2000-01-01',end:'2999-12-31'},officerFilter:'owner-new'})`);
const officer=run(`buildArrearsRows({portfolioView:false,groupIds:['group-new'],dateRange:{start:'2000-01-01',end:'2999-12-31'}})`);
assert.equal(admin.length,officer.length);assert.equal(admin[0].arrears,officer[0].arrears);
assert.equal(run(`loanBalanceInfo(state.data.loans[0]).paid`),100);
assert.equal(run(`dateInReportRange('2026-08-21','2026-09-25T00:00:00Z',{start:'2026-09-01',end:'2026-09-30'})`),false,'backdated cash stays in its payment period');
run(`state.data.excessPayments=[{id:'deposit',original_repayment_id:'cash',source:'scheduled_prepayment',status:'pending',original_payment_amount:400,amount_applied_to_loan:100,excess_amount:300}];`);
assert.equal(run(`repaymentCashReceived({id:'cash',amount:100,status:'approved'})`),400);
assert.equal(run(`countsAsCashReceived({id:'release',amount:100,status:'approved',notes:'Scheduled prepayment release: deposit'})`),false);
assert.equal(run(`loanFinancialMetrics({...state.data.loans[0],id:'release-loan'},'2026-09-25').paid`),0);

// Legacy loan totals can have fractional cents. The portfolio must sum the
// same rounded loan balances shown in management reports and the SQL audit.
run(`state.data.loans=[0,1].map(n=>({...fixtureLoan,id:'fraction-'+n,total_payable:1000.004,
  member_id:'member',group_id:'group-new',officer_id:'owner-new',status:'active'}));
  state.data.repayments=[];pageOfficerDashboard();`);
assert.match(node.innerHTML,/Outstanding balance<\/div><div class="v">KES 2,000<\/div>/);
run(`state.data.loans=[{...fixtureLoan,member_id:'member',group_id:'group-old',officer_id:'owner-old',status:'active'}];
  state.data.repayments=fixturePayments;`);

(async()=>{
  // A pending-only refresh must never advance a complete-history sync cursor.
  run(`readFinancialCache=async()=>({fullSyncAt:100,reconciledAt:150,savedAt:200});
    writeFinancialCache=async(...args)=>{globalThis.cacheWrite=args;};toast=()=>{};`);
  await run(`persistPartialFinancialCache('pb_repayments',[])`);
  assert.deepEqual(Array.from(sandbox.cacheWrite).slice(2),[100,150,200]);
  // A server snapshot heals a previously cached wrong balance using only affected loans.
  run(`sb.rpc=async()=>({data:{version:1,authorized:true,complete:true,visibleLoanIds:['loan-a'],asOfDate:todayISO(),checkedAt:'2026-09-25T09:00:00Z',rows:[{id:'loan-a',paid:150,principalPaid:120,interestPaid:30,repaymentCount:1,repaymentUpdatedAt:null,status:'active',start_date:'2026-09-17',weekly_installment:100,loan_value:800,total_payable:1000,arrears:45,outstandingPI:850,group_id:'group-new',officer_id:'owner-new'}]}});
    fetchPagedBusinessRows=async()=>({data:[{id:'fixed',loan_id:'loan-a',amount:150,principal:120,interest:30,status:'approved',meeting_date:'2026-09-17'}]});`);
  assert.equal(await run(`refreshFinancialSnapshot()`),true);
  assert.equal(run(`loanBalanceInfo(state.data.loans[0]).outstandingPI`),850);
  assert.equal(run(`state.data.repayments.length`),1);
  assert.equal(run(`state.data.repayments[0].id`),'fixed');
  // Dashboard/export parity includes officer and date filters.
  let exported;sandbox.XLSX={utils:{book_new:()=>({}),json_to_sheet:rows=>(exported=rows),book_append_sheet(){}},writeFile(){}};
  run(`state._arrearsTab='arrears';state._arrearsOfficerFilter='owner-new';exportArrearsCollectionSheet();`);
  assert.equal(exported.length,1);assert.equal(exported[0]['Total Arrears (KES)'],45);
  // Switching must authenticate the selected account and clear old data.
  run(`modal=config=>{globalThis.switchModal=config;};
    document.getElementById=id=>({value:id==='su-email'?'officer@example.test':id==='su-password'?'test-password':''});
    globalThis.loginCalls=[];
    sb.auth.signInWithPassword=async args=>{loginCalls.push(args);return {data:{session:{user:{id:'auth-target'}}}};};
    loadStaff=async()=>{state.staff={id:'target',business_id:'biz',role:'officer'};return true;};
    afterLogin=async()=>{};sha256=async()=> 'test-hash';closeModal=()=>{};render=()=>{};
    state.data.loans=[{id:'old-cached-loan'}];state._arrearsOfficerFilter='old-officer';state._loanOfficerFilter='old-officer';openSwitchUser();`);
  await run(`switchModal.actions[1].onClick()`);
  assert.equal(sandbox.loginCalls.length,1);
  assert.equal(sandbox.loginCalls[0].email,'officer@example.test');
  assert.equal(run('state.data.loans.length'),0,'old account data cleared');
  assert.equal(run('state.staff.id'),'target');
  assert.equal(run('state.session.user.id'),'auth-target');
  assert.equal(run('state._arrearsOfficerFilter'),'');assert.equal(run('state._loanOfficerFilter'),'');
  console.log('Financial rules and application regressions passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
