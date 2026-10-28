const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const rules=require('../financial-rules.js');

const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const node={innerHTML:'',style:{},classList:{toggle(){},add(){},remove(){}}};
const sandbox={WamamaFinance:rules,console,Intl,Date,URL,Map,Set,Promise,
  window:{addEventListener(){}},document:{addEventListener(){},getElementById(){return node},querySelector(){return null},documentElement:node},
  navigator:{onLine:true},localStorage:{getItem(){return null},setItem(){},removeItem(){}},sessionStorage:{getItem(){return null},setItem(){},removeItem(){}},
  setInterval(){},setTimeout(){return 1},clearTimeout(){},requestAnimationFrame(){},
  supabase:{createClient(){return {auth:{onAuthStateChange(){}}}}}};
vm.createContext(sandbox);
vm.runInContext(code.slice(0,code.indexOf('(async function boot(){')).replace('const todayISO = () => kenyaDateISO(new Date());',"const todayISO = () => '2026-10-13';"),sandbox);
const run=script=>vm.runInContext(script,sandbox);

run(`state.staff={id:'admin',role:'admin',app_role:'admin',business_id:'biz'};
  state.data.staff=[{id:'officer',full_name:'Loan Officer'}];
  state.data.groups=[{id:'group',name:'Test Group',officer_id:'officer',status:'active'}];
  state.data.members=[{id:'member',group_id:'group',full_name:'Test Member',status:'active'}];
  state.data.loans=[];state.data.repayments=[];state.data.savings=[];state.data.orders=[];
  state.data.excessPayments=[
    {member_id:'member',payment_date:'2026-10-01',excess_amount:100,released_amount:20,status:'pending'},
    {member_id:'member',payment_date:'2026-10-02',excess_amount:50,released_amount:0,status:'pending'},
    {member_id:'member',payment_date:'2026-10-01',excess_amount:90,released_amount:0,status:'refunded'}
  ];
  state._collectionWeekStart='2026-10-12';`);
const admin=run('buildCollectionCompliance().memberRows[0].loanDeposits');
assert.equal(admin,130);
run(`state.staff={id:'officer',role:'loan_officer',app_role:'loan_officer',business_id:'biz'};
  state.data.excessPayments=[];
  state._officerLoanDepositsReady=false;
  invalidateCollectionComplianceCache();`);
assert.equal(run('buildCollectionCompliance().memberRows[0].loanDeposits'),null,'missing feed is not shown as zero');
run(`state._officerLoanDepositRows=[
  {member_id:'member',payment_date:'2026-10-01',available_amount:80},
  {member_id:'member',payment_date:'2026-10-02',available_amount:50}
  ];state._officerLoanDepositsReady=true;invalidateCollectionComplianceCache();`);
assert.equal(run('buildCollectionCompliance().memberRows[0].loanDeposits'),admin,'officer and admin see the same client deposit');
assert.equal(run('buildCollectionCompliance().groupRows[0].loanDeposits'),admin,'group total agrees too');
assert.equal(run("loanDepositsByDate('member','2026-10-01')"),80,'the report date is respected');
run(`state.session={user:{id:'auth-officer'}};state.view='collection_compliance';
  sb.rpc=async name=>name==='pb_release_due_prepayments'?{data:0,error:null}:{data:[{member_id:'member',payment_date:'2026-10-01',available_amount:80}],error:null};`);
(async()=>{
  assert.equal(await run('ensureOfficerLoanDepositsForExport()'),true,'export verifies a fresh database balance');
  run(`sb.rpc=async()=>({data:null,error:{message:'Service unavailable'}});
    toast=()=>{};`);
  assert.equal(await run('ensureOfficerLoanDepositsForExport()'),false,'export stops when the balance cannot be verified');
  console.log('Admin and officer deposit parity, date cutoff and safe PDF export passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
