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

run(`
state._recruitmentMonth='2026-10';
state._recruitmentOfficer='one';
state._productSalesMonth='2026-10';
state._productSalesOfficer='one';
state._productSalesSearch='plastic chair';
state.data.staff=[{id:'one',full_name:'Officer One'},{id:'two',full_name:'Officer Two'}];
state.data.groups=[{id:'g',name:'Transferred Group',officer_id:'two'}];
state.data.members=[
 {id:'m1',full_name:'Same Name',officer_id:'one',group_id:'g',registered_on:'2026-10-31',status:'active'},
 {id:'m2',full_name:'Same Name',officer_id:'one',group_id:'g',registered_on:'2026-10-01',status:'inactive'},
 {id:'m3',full_name:'Pending',officer_id:'one',group_id:'g',registered_on:'2026-10-01',status:'pending'},
 {id:'m4',full_name:'Other Month',officer_id:'one',group_id:'g',registered_on:'2026-11-01',status:'active'},
 {id:'m5',full_name:'Other Officer',officer_id:'two',group_id:'g',registered_on:'2026-10-01',status:'active'}
];
state.data.orders=[{id:'order',ordered_on:'2026-10-31',notes:'{}'}];
state.data.loans=[
 {id:'l1',officer_id:'one',member_id:'m1',order_id:'order',status:'active',loan_value:2500,total_payable:2800,sold_items:[{asset_name:'Easy Plastic Chair',quantity:2,principal:2000},{asset_name:'Jug',quantity:1,principal:500}]},
 {id:'l2',officer_id:'two',member_id:'m2',order_id:'order',status:'active',loan_value:1000,total_payable:1120,asset_name:'Easy Plastic Chair (x1)',asset_quantity:1},
 {id:'l3',officer_id:'one',member_id:'m1',order_id:'order',status:'cancelled',loan_value:1000,total_payable:1120,asset_name:'Easy Plastic Chair (x1)',asset_quantity:1}
];
`);
const recruitment=run('buildRecruitmentReport()');
assert.equal(recruitment.rows.length,2);
assert.equal(recruitment.summary[0].ClientsRecruited,2);
const sales=run('buildProductSalesReport()');
assert.equal(sales.details.length,1);
assert.equal(sales.summary[0].quantity,2);
assert.equal(sales.details[0].officerId,'one');
assert.equal(sales.details[0].principal,2000);
const legacy=run("productLinesForLoan({asset_name:'Easy Plastic Chair (x2), Teapot (x1)',asset_quantity:3,loan_value:3000})");
assert.equal(legacy.length,2);
assert.equal(legacy[0].quantity,2);
assert.match(legacy[0].valueBasis,/Estimated/);
const workbooks=[];
sandbox.XLSX={utils:{book_new(){return {sheets:[]}},json_to_sheet(rows){return rows},book_append_sheet(book,rows,name){book.sheets.push({rows,name})}},writeFile(book,name){workbooks.push({book,name})}};
run('toast=()=>{}');
run('exportRecruitmentReport()');
run('exportProductSalesReport()');
assert.equal(workbooks[0].book.sheets.find(sheet=>sheet.name==='Recruited Clients').rows.length,2);
assert.equal(workbooks[1].book.sheets.find(sheet=>sheet.name==='Sales Details').rows.length,1);
assert.equal(workbooks[1].book.sheets.find(sheet=>sheet.name==='Officer Summary').rows[0].UnitsSold,2);
console.log('Monthly officer filtering, recruitment status/date boundaries, recorded officer attribution, combined chair quantities and filtered Excel sheets passed.');
