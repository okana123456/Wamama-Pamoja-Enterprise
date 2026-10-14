const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
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
run(`state.data.repayments=[
 {id:'pay1',loan_id:'one',amount:200,status:'approved',meeting_date:'2026-10-01'},
 {id:'pay2',loan_id:'two',amount:100,status:'approved',meeting_date:'2026-10-08'}];
 const group={id:'g',name:'Test Group'};
 const report={start:'2026-10-12',end:'2026-10-18',arrearsCutoff:'2026-10-14',
 groupRows:[{group,officer:{full_name:'Officer'},members:2,products:2}],
 memberRows:[{group,member:{id:'m',full_name:'Rose'},savings:6200,loanDeposits:388,
 loans:[{id:'two',asset_name:'Cement',total_payable:2000,weekly_installment:200,start_date:'2026-10-08',expected_end_date:'2026-12-10'},
 {id:'one',asset_name:'Plates',total_payable:1000,weekly_installment:100,start_date:'2026-10-01',expected_end_date:'2026-12-03'}]},
 {group,member:{id:'n',full_name:'No loan'},savings:50,loanDeposits:0,loans:[]}]};`);
const rows=run('collectionFieldSheetRows(report.groupRows[0],report)');
assert.equal(rows.length,3);const loans=rows.filter(r=>r.memberId==='m');
assert.deepEqual(Array.from(loans,r=>r.loanId),['one','two']);
assert.deepEqual(Array.from(loans,r=>r.product),['Plates','Cement']);
assert.deepEqual(Array.from(loans,r=>r.olb),[800,1900]);
assert.deepEqual(Array.from(loans,r=>r.start),['2026-10-01','2026-10-08']);
assert.deepEqual(Array.from(loans,r=>r.end),['2026-12-03','2026-12-10']);
assert.deepEqual(Array.from(loans,r=>r.lastPaid),['2026-10-01','2026-10-08']);
assert.equal(loans[0].savings,6200);assert.equal(loans[1].savings,null);
assert.equal(loans[0].loanDeposits,388);assert.equal(loans[1].loanDeposits,null);
const captures=[];
sandbox.window.jspdf={jsPDF:class {
 constructor(){this.internal={pageSize:{width:297,height:210},getNumberOfPages(){return 1}};this.lastAutoTable={finalY:100};}
 setFillColor(){} rect(){} setTextColor(){} setFont(){} setFontSize(){} text(t){captures.push(t)}
 roundedRect(){} autoTable(o){captures.push(o.body)} save(){} addPage(){}
}};
run('financialFiguresReady=()=>true;ensureOfficerLoanDepositsForExport=async()=>true;buildCollectionCompliance=()=>report;toast=()=>{};');
(async()=>{
 await run('downloadCollectionFieldSheetPdf()');
 const body=captures.find(Array.isArray),total=body.at(-1);
 assert.equal(total[3],run('KES(388)'),'continued loan rows do not hide deposit total');
 assert.equal(total[2],run('KES(6250)'),'savings counted once per member');
 assert.equal(total[5],run('KES(3000)'));assert.equal(total[6],run('KES(2700)'));
 assert(captures.some(t=>typeof t==='string'&&t.includes('Clients listed: 2')));
 console.log('Separate loan dates, balances and payments; shared balances counted once; PDF totals passed.');
})().catch(e=>{console.error(e);process.exitCode=1;});
