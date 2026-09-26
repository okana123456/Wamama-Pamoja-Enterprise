const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const rules=require('../financial-rules.js');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const script=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
class FixedDate extends Date {constructor(...args){super(...(args.length?args:['2026-09-26T10:00:00+03:00']));}static now(){return new FixedDate().getTime();}}
const page={innerHTML:''},modal={hasChildNodes:()=>false};
const sandbox={WamamaFinance:rules,console,Intl,Date:FixedDate,URL,Map,Set,Promise,AbortController,
 window:{addEventListener(){},location:{reload(){sandbox.reloads=(sandbox.reloads||0)+1;}}},
 document:{visibilityState:'visible',addEventListener(){},getElementById:id=>id==='page'?page:id==='modal-root'?modal:{},querySelector:()=>null},
 navigator:{onLine:true},localStorage:{getItem:()=>null,setItem(){},removeItem(){}},sessionStorage:{getItem:()=>null,setItem(){},removeItem(){}},
 setInterval(){},setTimeout(){return 1;},clearTimeout(){},requestAnimationFrame(){},
 supabase:{createClient:()=>({auth:{onAuthStateChange(){}}})}};
vm.createContext(sandbox);
vm.runInContext(script.slice(0,script.indexOf('(async function boot(){')),sandbox);
const run=code=>vm.runInContext(code,sandbox);
const staff=[{id:'admin',role:'admin',app_role:'admin',status:'active'},
 {id:'a',role:'loan_officer',status:'active',full_name:'Officer A'},
 {id:'b',role:'loan_officer',status:'active',full_name:'Officer B'}];
const makeLoan=(id,group,start,extra={})=>({id,group_id:group,member_id:id,officer_id:'b',status:'active',
 asset_name:id,loan_value:800,total_payable:1000,weekly_installment:100,start_date:start,...extra});
const loans=[makeLoan('part','ga','2026-09-19'),makeLoan('transfer','gb','2026-09-12'),
 makeLoan('today','ga','2026-09-26'),makeLoan('fraction','ga','2026-10-03',{total_payable:1000.004}),
 makeLoan('closed','ga','2026-09-01',{status:'completed'}),makeLoan('duplicate','ga','2026-09-01',{status:'cancelled'}),
 makeLoan('pending','ga','2026-09-01',{status:'pending'}),makeLoan('other','gb','2026-09-26'),
 makeLoan('other-arrears','gb','2026-09-19')];
const pay=(id,loan,amount,date,extra={})=>({id,loan_id:loan,amount,principal:amount*.8,interest:amount*.2,
 status:'approved',meeting_date:date,recorded_by:'a',group_id:'ga',...extra});
const repayments=[pay('cash','part',50,'2026-09-19'),pay('trans-cash','transfer',100,'2026-09-20'),
 pay('paid','closed',1000,'2026-09-01'),pay('void','part',900,'2026-09-20',{voided_at:'2026-09-21'}),
 pay('awaiting','part',800,'2026-09-20',{status:'pending'}),pay('future','part',700,'2026-10-03'),
 pay('wrong','part',600,'2026-09-20',{status:'rejected'})];
const savings=[{id:'sav',recorded_by:'a',group_id:'ga',meeting_date:'2026-09-20',status:'approved',amount:100},
 {id:'old-group-sav',recorded_by:'a',group_id:'gb',meeting_date:'2026-09-18',status:'approved',amount:30},
 {id:'not-approved',recorded_by:'a',group_id:'ga',meeting_date:'2026-09-20',status:'pending',amount:900},
 {id:'void-sav',recorded_by:'a',group_id:'ga',meeting_date:'2026-09-20',status:'approved',amount:900,voided_at:'2026-09-21'},
 {id:'other-sav',recorded_by:'b',group_id:'gb',meeting_date:'2026-09-20',status:'approved',amount:800}];
sandbox.fixture={staff,loans,repayments,savings,
 groups:[{id:'ga',officer_id:'a',name:'A group'},{id:'gb',officer_id:'b',name:'B group'}],
 members:loans.map(l=>({id:l.id,group_id:l.id==='transfer'?'ga':l.group_id,full_name:l.id}))};
run(`state.staff=fixture.staff[0];state.session={user:{id:'admin-auth'}};
 Object.assign(state.data,fixture);state._portfolioDataVerified=true;state._financialSnapshotAvailable=true;
 state._financialSnapshot={asOfDate:todayISO(),checkedAt:new Date().toISOString(),byLoan:new Map()};
 _dashFilter='month';_reportFilter='month';state._reportOfficerFilter='a';
 for(const range of [dashDateRange(),{start:todayISO(),end:todayISO()}]){
  cashSnapshots.set(cashSnapshotKey(range),{rows:range.start===todayISO()?[]:[
    {recordedBy:'a',groupId:'ga',amount:1500,interest:230,entries:3},
    {recordedBy:'a',groupId:'gb',amount:60,interest:12,entries:1},
    {recordedBy:'b',groupId:'gb',amount:9000,interest:500,entries:20}]});
 }`);
const raw=run(`buildReportRows('management_summary')[0]`);
assert.equal(raw.ActiveLoans,4);
assert.equal(raw.OutstandingPI,3850);
assert.equal(raw.AccountsInArrears,2);
assert.equal(raw.PARArrears,140);
assert.equal(raw.SavingsMobilized,130);
assert.equal(raw.Collections,1560,'held cash uses authorized receipt totals, not applied amounts');
assert.equal(raw.InterestCollected,242);
assert.equal(raw.LoansDisbursed,3200,'cancelled duplicates and pending applications are not issued loans');
function kpi(label){
 const escaped=label.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
 const match=page.innerHTML.match(new RegExp(`<div class="l">${escaped}</div><div class="v">([^<]+)</div>`));
 assert.ok(match,`Missing KPI: ${label}`);return match[1];
}
function dashboardFigures(){return {active:kpi('Active loans I manage'),olb:kpi('Outstanding balance'),
 arrears:kpi('Accounts in arrears'),cash:kpi('Repayments recorded'),savings:kpi('Savings recorded'),issued:kpi('Loans issued')};}
run(`state._dashboardOfficerFilter='a';pageDashboard();`);
const managementDashboard=dashboardFigures();
assert.deepEqual(managementDashboard,{active:'4',olb:'KES 3,850',arrears:'2',cash:'KES 1,560',savings:'KES 130',issued:'KES 3,200'});
assert.match(page.innerHTML,/KES 140 overdue/);
run(`productSalesReportHtml=()=>'';pageReports();`);
assert.equal(kpi('Active loans'),'4');assert.equal(kpi('Accounts in arrears'),'2');
assert.equal(kpi('Outstanding P + I'),'KES 3,850');assert.equal(kpi('PAR / arrears'),'KES 140');
assert.equal(kpi('Collections'),'KES 1,560');assert.equal(kpi('Savings'),'KES 130');
let exported;
sandbox.XLSX={utils:{book_new:()=>({}),json_to_sheet:rows=>(exported=rows),book_append_sheet(){}},writeFile(){}};
run(`toast=()=>{};exportReport('management_summary');`);
assert.deepEqual(JSON.parse(JSON.stringify(exported[0])),JSON.parse(JSON.stringify(raw)));
// Management's tab badges, callout, totals and export must use the chosen officer,
// not branch totals above a correctly filtered table (the production screenshot bug).
run(`state._arrearsOfficerFilter='a';state._arrearsTab='arrears';pageArrears();`);
assert.match(page.innerHTML,/In Arrears \(2\)/);assert.match(page.innerHTML,/All Active \(4\)/);
assert.match(page.innerHTML,/Due Today \(3\)/);assert.match(page.innerHTML,/Due Next 7 Days \(1\)/);
assert.match(page.innerHTML,/🔔 3 Due Today — Collect Now/);
assert.match(page.innerHTML,/2 loans · Arrears KES 140/);
assert.match(page.innerHTML,/<option value="b"/,'other officer remains selectable');
assert.doesNotMatch(page.innerHTML,/<b>other-arrears<\/b>/);
run(`exportArrearsCollectionSheet();`);
assert.equal(exported.length,2);assert.equal(exported.reduce((n,r)=>n+r['Total Arrears (KES)'],0),140);
assert.ok(exported.every(r=>r['Officer Name']==='Officer A'));
run(`state._arrearsTab='duetoday';pageArrears();`);
assert.match(page.innerHTML,/3 loans · Arrears KES 140/);
run(`state._arrearsTab='all';pageArrears();`);
assert.match(page.innerHTML,/4 loans · Arrears KES 140/);
run(`state._arrearsOfficerFilter='';state._arrearsTab='arrears';pageArrears();`);
assert.match(page.innerHTML,/In Arrears \(3\)/,'clearing the officer shows branch totals');
// Separately authenticated officer data is scoped and cannot see raw deposits.
run(`state.staff=fixture.staff[1];state._dashboardOfficerFilter='';
 state.data.loans=fixture.loans.filter(l=>loanBelongsToCurrentOfficer(l,'a'));
 state.data.excessPayments=[];
 for(const range of [dashDateRange(),{start:todayISO(),end:todayISO()}]){
  cashSnapshots.set(cashSnapshotKey(range),{rows:range.start===todayISO()?[]:[
   {recordedBy:'a',groupId:'ga',amount:1500,interest:230,entries:3},
   {recordedBy:'a',groupId:'gb',amount:60,interest:12,entries:1}]});
 }
 pageDashboard();`);
assert.deepEqual(dashboardFigures(),managementDashboard,'admin-selected view equals actual officer view');
run(`state._arrearsOfficerFilter='b';pageArrears();`);
assert.match(page.innerHTML,/In Arrears \(2\)/,'officer ignores a stale management officer filter');
run(`exportArrearsCollectionSheet();`);
assert.equal(exported.length,2);assert.ok(exported.every(r=>r['Officer Name']==='Officer A'));
// Date changes affect activity, never today's outstanding balances or arrears.
run(`_dashFilter='today';_reportFilter='today';pageDashboard();`);
assert.equal(kpi('Repayments recorded'),'KES 0');assert.equal(kpi('Outstanding balance'),'KES 3,850');
assert.equal(kpi('Accounts in arrears'),'2');assert.equal(kpi('Loans issued'),'KES 800');
const today=run(`buildReportRows('management_summary')[0]`);
assert.equal(today.Collections,0);assert.equal(today.OutstandingPI,3850);assert.equal(today.AccountsInArrears,2);
// Narrowing a management report must apply the same portfolio scope to all totals.
run(`state.data.loans=fixture.loans;state.staff=fixture.staff[0];_reportFilter='month';state._reportGroupFilter='gb';`);
const group=run(`buildReportRows('management_summary')[0]`);
assert.equal(group.ActiveLoans,0,'transferred member now belongs to ga');assert.equal(group.Collections,60);
run(`state._reportGroupFilter='';state._reportLoanStatusFilter='completed';`);
const closed=run(`buildReportRows('management_summary')[0]`);
assert.equal(closed.OutstandingPI,0);assert.equal(closed.AccountsInArrears,0);
// A newly verified approval reaches every view even while its local cache lags.
run(`state._reportLoanStatusFilter='';_dashFilter='month';
 state._financialSnapshot.byLoan.set('part',{...loanFinancialMetrics(state.data.loans[0]),
  id:'part',group_id:'ga',officer_id:'a',paid:150,outstandingPI:850,outstandingPrincipal:680,arrears:0});
 state._dashboardOfficerFilter='a';pageDashboard();`);
assert.equal(kpi('Outstanding balance'),'KES 3,750');assert.equal(kpi('Accounts in arrears'),'1');
const updated=run(`buildReportRows('management_summary')[0]`);
assert.equal(updated.OutstandingPI,3750);assert.equal(updated.PARArrears,95);
run(`state.staff=fixture.staff[1];state._dashboardOfficerFilter='';pageDashboard();`);
assert.equal(kpi('Outstanding balance'),'KES 3,750');assert.equal(kpi('Accounts in arrears'),'1');
// Long lists must match in full, including records beyond a screenshot or preview.
sandbox.longLoans=[...Array.from({length:36},(_,i)=>makeLoan(`long-a-${i}`,'ga','2026-09-19')),
 ...Array.from({length:17},(_,i)=>makeLoan(`long-b-${i}`,'gb','2026-09-19'))];
run(`state.staff=fixture.staff[0];state.data.loans=longLoans;state.data.repayments=[];
 state.data.members=longLoans.map(l=>({id:l.id,group_id:l.group_id,full_name:l.id}));
 state._financialSnapshot.byLoan.clear();state._arrearsOfficerFilter='a';state._arrearsTab='arrears';pageArrears();`);
const fullList=()=>Array.from(page.innerHTML.matchAll(/<b>(long-a-\d+)<\/b>/g),m=>m[1]);
const managementFullList=fullList();
assert.equal(managementFullList.length,36);assert.match(page.innerHTML,/36 loans · Arrears KES 3,420/);
run(`exportArrearsCollectionSheet();`);
const managementFullExport=JSON.parse(JSON.stringify(exported));
assert.equal(managementFullExport.length,36);
run(`state.staff=fixture.staff[1];state.data.loans=longLoans.filter(l=>loanBelongsToCurrentOfficer(l,'a'));
 state._arrearsOfficerFilter='b';pageArrears();`);
assert.deepEqual(fullList(),managementFullList,'every arrears record matches across accounts');
assert.match(page.innerHTML,/36 loans · Arrears KES 3,420/);
run(`exportArrearsCollectionSheet();`);
assert.deepEqual(JSON.parse(JSON.stringify(exported)),managementFullExport,'complete exports match across accounts');
// Website upgrades wait for open entries and offline writes, then reload safely.
assert.equal(run(`canApplyAppUpdate()`),true);
modal.hasChildNodes=()=>true;assert.equal(run(`canApplyAppUpdate()`),false);
modal.hasChildNodes=()=>false;run(`state.view='meeting';`);assert.equal(run(`canApplyAppUpdate()`),false);
run(`state.view='dashboard';lsGet=()=>[{table:'pb_repayments',row:{}}];`);
assert.equal(run(`canApplyAppUpdate()`),false,'queued cash entries must finish before an update');
run(`lsGet=(key,fallback)=>fallback;`);
run(`state.view='dashboard';appUpdateAvailable=true;applyAvailableAppUpdate();`);
assert.equal(sandbox.reloads,1);assert.equal(run(`applyAvailableAppUpdate()`),false);
const release=JSON.parse(fs.readFileSync(path.join(__dirname,'../release.json'),'utf8'));
assert.equal(release.version,run(`APP_RELEASE`));
(async()=>{
 let checks=0;
 sandbox.fetch=async()=>{checks++;return {ok:true,json:async()=>({version:release.version})};};
 run(`appUpdateAvailable=false;appUpdateReloading=false;appUpdateCheckAt=0;`);
 await run(`checkAppRelease()`);await run(`checkAppRelease()`);
 assert.equal(checks,1,'throttled static check uses no extra database requests');
 assert.equal(sandbox.reloads,1,'current release does not reload');
 sandbox.fetch=async()=>({ok:true,json:async()=>({version:'next-release'})});
 modal.hasChildNodes=()=>true;run(`appUpdateCheckAt=0;`);await run(`checkAppRelease()`);
 assert.equal(sandbox.reloads,1,'open entry dialog defers new release');
 assert.equal(run(`appUpdateAvailable`),true);
 modal.hasChildNodes=()=>false;await run(`checkAppRelease()`);
 assert.equal(sandbox.reloads,2,'safe reporting page upgrades when the entry closes');
 console.log('Rendered admin dashboard, officer dashboard, management report and Excel parity passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
