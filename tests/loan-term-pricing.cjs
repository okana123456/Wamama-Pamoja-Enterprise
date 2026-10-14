const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
new vm.Script(code);
const elements={};
const node=()=>({value:'',max:'0',innerHTML:'',textContent:'',style:{},dataset:{},addEventListener(){},classList:{toggle(){},add(){},remove(){}}});
const element=id=>elements[id]||(elements[id]=node());
const sandbox={WamamaFinance:require('../financial-rules.js'),console,Intl,Date,URL,Map,Set,Promise,
  window:{addEventListener(){}},document:{addEventListener(){},getElementById:element,querySelector(){return null},documentElement:node()},
  navigator:{onLine:true},localStorage:{getItem(){return null},setItem(){},removeItem(){}},sessionStorage:{getItem(){return null},setItem(){},removeItem(){}},
  setInterval(){},setTimeout(){return 1},clearTimeout(){},requestAnimationFrame(){},
  supabase:{createClient(){return {auth:{onAuthStateChange(){}}}}}};
vm.createContext(sandbox);
vm.runInContext(code.slice(0,code.indexOf('(async function boot(){')),sandbox);
const run=s=>vm.runInContext(s,sandbox);
run('state.settings={monthly_interest_rate:2};');
const q=run('flatLoanQuote(2450,12)');
assert.equal(q.totalInterest,147);assert.equal(q.fees,147);assert.equal(q.grandTotal,2744);
assert.equal(q.suggestedWeekly,228.67);assert.equal(q.finalInstallment,228.63);
for(const [weeks,total] of [[11,2731.75],[12,2744],[13,2756.25]]){
  const schedule=run(`computeSchedule(2450,228.67,'flat',new Date('2026-10-13'),${weeks})`);
  assert.equal(schedule.grandTotal,total);assert.equal(schedule.weeks,weeks);assert.equal(schedule.rows.length,weeks);
  assert.equal(Math.round(schedule.rows.reduce((sum,row)=>sum+row.installment,0)*100),Math.round(total*100));
  assert.equal(schedule.rows.at(-1).balance,0);
}
assert.equal(run("computeSchedule(2450,228.67,'flat',new Date()).weeks"),12);
const historic=run("storedLoanSchedule({loan_value:2450,total_payable:2760.1,weekly_installment:230.01,start_date:'2026-10-13'})");
run('state.settings.monthly_interest_rate=9;');
const historicAfter=run("storedLoanSchedule({loan_value:2450,total_payable:2760.1,weekly_installment:230.01,start_date:'2026-10-13'})");
assert.deepEqual(historicAfter,historic,'a rate change cannot reprice an issued loan schedule');
run('state.settings.monthly_interest_rate=2;');
element('al-weeks').value='12';element('wi').value='230.01';element('sd').value='2026-10-13';
run('recalculateApprovalTerms(2450,true)');
assert.equal(element('wi').value,'228.67');assert.equal(element('al-total-value').textContent,'KES 2,744');
assert.equal(element('al-actual-weeks').textContent,'12 weeks');
element('al-deposit').max='450';element('al-deposit').value='450';
run('recalculateApprovalTerms(2450,true)');
assert.equal(element('al-total-value').textContent,'KES 2,240','deposit reduces the interest and fee base');
element('al-deposit').value='0';element('al-deposit').max='0';
element('c-amount').value='2450';element('c-weeks').value='12';element('c-start').value='2026-10-13';
run('runCalc()');assert.equal(element('c-weekly').value,'228.67');assert.match(element('calc-out').innerHTML,/KES 2,744/);
element('ord-weeks').value='12';
run("_orderLines=[{loan_price:2450,quantity:1}];ordCalcFromWeeks()");
assert.equal(element('ord-wi').value,'228.67');assert.match(element('ord-loan-out').innerHTML,/KES 2,744/);

(async()=>{
  run(`state.staff={id:'admin',business_id:'biz',role:'admin'};
    state.data.members=[{id:'member',group_id:'group',full_name:'Beryl'}];
    state.data.groups=[{id:'group',officer_id:'officer'}];
    state.data.inventory=[{id:'asset',name:'Item',loan_price:2450,stock:10}];
    state.data.excessPayments=[];state.data.loans=[];
    memberSavings=()=>9200;modal=config=>{globalThis.approval=config};
    ensureFreshToken=async()=>true;audit=()=>{};toast=()=>{};closeModal=()=>{};refreshVisiblePage=()=>{};
    sb.from=table=>{
      const builder={select(){return this},eq(){return this},is(){return this},
        insert(row){this.row=row;if(table==='pb_loans')globalThis.savedLoan=row;return this},update(){return this},
        single:async function(){return {data:{id:'new-loan',...this.row},error:null}},
        then(resolve,reject){return Promise.resolve({data:[],error:null}).then(resolve,reject)}};
      return builder;
    };
    approveOrder({id:'order',member_id:'member',asset_id:'asset',asset_name:'Item',quantity:1,desired_weeks:12,desired_weekly_installment:230.01});`);
  element('al-weeks').value='12';element('wi').value='999'; // Save must calculate, not trust stale input.
  await run('approval.actions[1].onClick()');
  assert.equal(sandbox.savedLoan.total_payable,2744);
  assert.equal(sandbox.savedLoan.weekly_installment,228.67);
  assert.equal(sandbox.savedLoan.agreed_term_weeks,12);
  assert.equal(sandbox.savedLoan.expected_end_date,'2026-12-29');
  console.log('Flat pricing, rounding, deposit, order/calculator/approval/save parity, and historical schedule preservation passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
