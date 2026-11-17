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
state.staff={id:'admin',role:'admin',app_role:'admin',business_id:'biz'};
state.view='reports';state._portfolioDataVerified=true;state._financialSnapshotAvailable=false;
state._recruitmentMonth='2026-11';state._productSalesMonth='2026-11';
state.data.staff=[{id:'one',full_name:'Officer One',role:'loan_officer',status:'active'}];
state.data.groups=[{id:'g',name:'Group',officer_id:'one'}];
state.data.members=Array.from({length:61},(_,index)=>({id:'m'+index,full_name:'Client '+index,registered_on:'2026-11-01',officer_id:'one',group_id:'g',status:'active'}));
state.data.loans=state.data.members.map((member,index)=>({id:'l'+index,member_id:member.id,officer_id:'one',group_id:'g',asset_name:'Plastic Chair '+index+' (x1)',asset_quantity:1,loan_value:100,total_payable:112,start_date:'2026-11-01',status:'active'}));
ensureCashTotals=()=>true;ensureBookActivity=()=>true;
const officerRows=Array.from({length:61},(_,index)=>({Officer:'Officer '+index,ActiveLoans:1,AccountsInArrears:0,PARArrears:0,ClientsRecruited:1,GroupsCreated:0,SavingsMobilized:0,LoansDisbursed:100,LoansClosed:0,ClientAccountsClosed:0,Collections:0,RecordedSavings:0,RecordedCollections:0,OutstandingPrincipal:100,OutstandingPI:112}));
buildReportRows=()=>officerRows;
`);
const rowCount=()=> (node.innerHTML.match(/<tr>/g)||[]).length;
run('pageReports()');
assert.equal(rowCount(),26);
assert.match(node.innerHTML,/<h3>Officer performance<\/h3>/);
assert.doesNotMatch(node.innerHTML,/<h3>Monthly Client Recruitment<\/h3>/);
assert.doesNotMatch(node.innerHTML,/<h3>Monthly Product Sales<\/h3>/);
run("state._reportOfficerPage=2;pageReports()");
assert.equal(rowCount(),12);
run("ensureCashTotals=()=>{throw Error('Unexpected cash fetch')};ensureBookActivity=()=>{throw Error('Unexpected book fetch')};state._reportSection='recruitment';pageReports()");
assert.equal(rowCount(),26);
assert.match(node.innerHTML,/Page 1 of 3/);
assert.doesNotMatch(node.innerHTML,/<h3>Officer performance<\/h3>/);
run("state._recruitmentPage=2;pageReports()");
assert.equal(rowCount(),12);
run("state._reportSection='product_sales';pageReports()");
assert.equal(rowCount(),26);
assert.doesNotMatch(node.innerHTML,/<h3>Monthly Client Recruitment<\/h3>/);
run("state._productSalesPage=2;pageReports()");
assert.equal(rowCount(),12);
const exportedBooks=[];
sandbox.XLSX={utils:{book_new(){return {sheets:[]}},json_to_sheet(rows){return rows},book_append_sheet(book,rows,name){book.sheets.push({name,rows})}},writeFile(book){exportedBooks.push(book)}};
run('toast=()=>{};exportRecruitmentReport();exportProductSalesReport()');
assert.equal(exportedBooks[0].sheets.find(sheet=>sheet.name==='Recruited Clients').rows.length,61);
assert.equal(exportedBooks[1].sheets.find(sheet=>sheet.name==='Product Summary').rows.length,61);
assert.equal(exportedBooks[1].sheets.find(sheet=>sheet.name==='Sales Details').rows.length,61);
run("state._reportSection='other_reports';pageReports()");
assert.match(node.innerHTML,/Members directory/);
assert.doesNotMatch(node.innerHTML,/<h3>Officer performance<\/h3>/);
console.log('Report selector renders one report, all three tables have 25-row pages, independent monthly views skip book fetches, and Excel exports all 61 records.');
