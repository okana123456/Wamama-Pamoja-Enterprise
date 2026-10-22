const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),{performance}=require('node:perf_hooks');
const html=fs.readFileSync(require('node:path').join(__dirname,'../index.html'),'utf8');
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const node={style:{},classList:{toggle(){},add(){},remove(){}}};
const sandbox={WamamaFinance:require('../financial-rules.js'),console,Intl,Date,URL,Map,Set,Promise,
 window:{addEventListener(){}},document:{addEventListener(){},getElementById(){return node},querySelector(){return null},documentElement:node},
 navigator:{onLine:true},localStorage:{getItem(){return null},setItem(){},removeItem(){}},sessionStorage:{getItem(){return null},setItem(){},removeItem(){}},
 setInterval(){},setTimeout(){return 1},clearTimeout(){},requestAnimationFrame(){},
 supabase:{createClient(){return {auth:{onAuthStateChange(){}}}}}};
vm.createContext(sandbox);vm.runInContext(code.slice(0,code.indexOf('(async function boot(){')),sandbox);
const run=s=>vm.runInContext(s,sandbox);
run(`state.staff={id:'admin',role:'admin',business_id:'biz'};
 state.data.loans=Array.from({length:2900},(_,i)=>({id:'l'+i,member_id:'m'+(i%1700),status:'active',start_date:'2026-09-01',loan_value:800,total_payable:1000,weekly_installment:100}));
 state.data.repayments=Array.from({length:31000},(_,i)=>({id:'r'+i,loan_id:'l'+(i%2900),amount:10,principal:8,interest:2,meeting_date:'2026-10-01',status:i%29===0?'rejected':i%23===0?'pending':'approved',voided_at:i%31===0?'2026-10-02':null}));
 state.data.excessPayments=Array.from({length:7800},(_,i)=>({original_repayment_id:'r'+i,source:'scheduled_prepayment',original_payment_amount:12,status:'pending'}));
 state.data.savings=Array.from({length:24000},(_,i)=>({id:'s'+i,member_id:'m'+(i%1700),amount:20,status:i%7===0?'pending':'approved'}));
 function calculation(){
   let cash=0,balance=0,savings=0;
   for(const r of state.data.repayments.slice(0,500)) if(countsAsCashReceived(r)) cash+=repaymentCashReceived(r);
   for(const l of state.data.loans.slice(0,300)) balance+=loanFinancialMetrics(l,'2026-10-15').outstandingPI;
   for(let i=0;i<200;i++) savings+=memberSavings('m'+i);
   return {cash,balance,savings};
 }`);
let start=performance.now();const slow=run('calculation()');const slowMs=performance.now()-start;
start=performance.now();const fast=run('withFinancialReadIndex(calculation)');const fastMs=performance.now()-start;
assert.deepEqual(fast,slow,'indexed calculations preserve all financial values');
assert.equal(run('financialReadScope'),null,'no cross-render cached ledger');
run(`state.data.repayments[1].voided_at='2026-10-16';state.data.savings[1].status='rejected';state.data.excessPayments[2].status='refunded';`);
assert.deepEqual(run('withFinancialReadIndex(calculation)'),run('calculation()'),'a later operation sees voids, approvals and deposit changes');
run(`state.data.repayments=[];state.data.savings=[];state.data.excessPayments=[];state._accountEpoch++;`);
const cleared=run('withFinancialReadIndex(calculation)');assert.equal(cleared.cash,0);assert.equal(cleared.savings,0);
assert.doesNotMatch(html,/<script[^>]+src=["']https:\/\/cdn\.jsdelivr\.net\/npm\/(xlsx|jspdf)/,'export tools must not block startup');
console.log(JSON.stringify({repayments:31000,savings:24000,deposits:7800,loans:2900,sampledCash:500,sampledLoans:300,sampledMembers:200,unindexed_ms:Math.round(slowMs),indexed_ms:Math.round(fastMs),speedup:Number((slowMs/fastMs).toFixed(1)),values_match:true}));
