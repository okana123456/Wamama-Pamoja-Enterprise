const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict'),path=require('path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const node={style:{},classList:{toggle(){},add(){},remove(){}}};
const sandbox={WamamaFinance:require('../financial-rules.js'),console,Intl,Date,URL,Map,Set,Promise,
 window:{addEventListener(){}},document:{addEventListener(){},getElementById(){return node},querySelector(){return null},documentElement:node},
 navigator:{onLine:true},localStorage:{getItem(){return null},setItem(){},removeItem(){}},sessionStorage:{getItem(){return null},setItem(){},removeItem(){}},
 setInterval(){},setTimeout(){return 1},clearTimeout(){},requestAnimationFrame(){},
 supabase:{createClient(){return {auth:{onAuthStateChange(){}}}}}};
vm.createContext(sandbox);vm.runInContext(code.slice(0,code.indexOf('(async function boot(){')),sandbox);
const run=s=>vm.runInContext(s,sandbox);

run(`state.data.repayments=[{id:'p',loan_id:'loan',amount:100,principal:90,interest:10,status:'approved',meeting_date:'2026-10-01'}];
const returned={id:'loan',status:'cancelled',loan_value:1000,total_payable:1200,weekly_installment:100,start_date:'2026-10-01',return_settlement:{settled_at:'2026-10-31T08:00:00Z'}};`);
const now=run("loanFinancialMetrics(returned,'2026-10-31')");assert.equal(now.outstandingPI,0);assert.equal(now.arrears,0);assert.equal(now.amountDue,0);assert.equal(now.paid,100);
const before=run("loanFinancialMetrics(returned,'2026-10-30')");assert.equal(before.outstandingPI,1100);
assert.match(html,/Return goods and settle\/cancel loan/);
console.log('Returned loan has zero current dues/balance while historical balances and original paid amount remain.');
