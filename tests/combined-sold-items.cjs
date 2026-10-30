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
run(`const sourceRows=[{member_id:'client',client_name:'Grace',phone:'0700000000',asset_id:'a',product:'Teapot',quantity:1,loan_amount:1200,loan_term:32},{member_id:'client',client_name:'Grace',phone:'0700000000',asset_id:'b',product:'Sufuria',quantity:1,loan_amount:4750,loan_term:32},{member_id:'client',client_name:'Grace',phone:'0700000000',asset_id:'c',product:'Seat',quantity:1,loan_amount:1600,loan_term:32},{member_id:'client',client_name:'Grace',phone:'0700000000',asset_id:'d',product:'Umbrella',quantity:1,loan_amount:350,loan_term:32}];result=soldItemsCombinedRows(sourceRows);`);
assert.equal(sandbox.result.length,1);let loan=sandbox.result[0];
assert.equal(loan.loan_amount,7900);assert.equal(loan.totalPayable,9638);assert.equal(loan.weeks,32);assert.equal(loan.items.length,4);assert.equal(loan.asset_id,null);
assert.throws(()=>run(`soldItemsCombinedRows([...sourceRows.slice(0,1),{...sourceRows[1],loan_term:12}])`),/same loan term/);
assert.equal(run(`soldItemsCombinedRows([...sourceRows,{...sourceRows[0],member_id:'other'}]).length`),2);
run(`state.data.orders=[];result=productLinesForLoan({sold_items:soldItemsCombinedRows(sourceRows)[0].items});`);
assert.equal(sandbox.result.length,4);assert.equal(sandbox.result.reduce((sum,line)=>sum+line.principal,0),7900);
console.log('Four products form one loan with combined principal/flat interest, different clients stay separate, inconsistent terms are blocked, product reporting retains all items.');
(async()=>{
 const saved=[];const controls={'si-group':{value:'group'},'si-date':{value:'2026-10-30'}};
 sandbox.document.getElementById=id=>controls[id]||null;
 sandbox.queryTable=table=>{
  const query={select(){return query},limit(){return Promise.resolve({error:null})},in(){return query},then(resolve){return Promise.resolve({data:[],error:null}).then(resolve)},
  insert(row){saved.push({table,row});return {select(){return {single:async()=>({data:{...row,id:table==='pb_orders'?'order':'loan'},error:null})}}}},
  update(){return {eq:async()=>({error:null})}}};return query;
 };
 run(`sb.from=queryTable;ensureFreshToken=async()=>true;closeModal=()=>{};refreshVisiblePage=()=>{};audit=()=>{};toast=()=>{};
 state.staff={id:'officer',business_id:'biz',full_name:'Officer'};
 state.data.members=[{id:'client',group_id:'group'}];state.data.groups=[{id:'group',officer_id:'officer'}];
 state.data.orders=[];state.data.loans=[];
 state.data.inventory=sourceRows.map(row=>({id:row.asset_id,name:row.product,loan_price:Number(row.loan_amount),stock:10}));
 _soldItems=sourceRows.map(row=>({...row}));`);
 await run('saveSoldItemsForm()');
 const loans=saved.filter(entry=>entry.table==='pb_loans');
 assert.equal(loans.length,1);assert.equal(loans[0].row.sold_items.length,4);
 assert.equal(loans[0].row.loan_value,7900);assert.equal(loans[0].row.weekly_installment,301.19);
 assert.equal(loans[0].row.start_date,'2026-11-06');assert.equal(loans[0].row.expected_end_date,'2027-06-11');
 assert.equal(JSON.parse(saved.find(entry=>entry.table==='pb_orders').row.notes).rows.length,1);
 console.log('Saving a four-product application inserts one loan with a single 32-week schedule.');
})().catch(error=>{console.error(error);process.exit(1)});
