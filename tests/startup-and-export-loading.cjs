const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const html=fs.readFileSync(require('node:path').join(__dirname,'../index.html'),'utf8');
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const page={innerHTML:'',style:{},classList:{toggle(){},add(){},remove(){}}};
const scripts=[];
const sandbox={WamamaFinance:require('../financial-rules.js'),console,Intl,Date,URL,Map,Set,Promise,
 window:{addEventListener(){}},document:{addEventListener(){},getElementById(){return page},querySelector(){return null},documentElement:page,
 createElement(){return {remove(){this.removed=true}}},head:{appendChild(script){scripts.push(script)}}},
 navigator:{onLine:true},localStorage:{getItem(){return null},setItem(){},removeItem(){}},sessionStorage:{getItem(){return null},setItem(){},removeItem(){}},
 setInterval(){},setTimeout(fn,ms){if(ms===0)fn();return 1},clearTimeout(){},requestAnimationFrame(){},
 supabase:{createClient(){return {auth:{onAuthStateChange(){}}}}}};
vm.createContext(sandbox);vm.runInContext(code.slice(0,code.indexOf('(async function boot(){')),sandbox);
const run=s=>vm.runInContext(s,sandbox),tick=()=>new Promise(resolve=>setImmediate(resolve));
(async()=>{
 assert.equal(scripts.length,0,'no export downloads on startup');
 let actions=0;sandbox.action=()=>++actions;
 const first=run("deferredExportAction(action,'excel')()");
 const second=run("deferredExportAction(action,'excel')()");
 assert.equal(scripts.length,1,'concurrent exports share one library request');
 assert.equal(actions,0);sandbox.XLSX={};scripts[0].onload();await Promise.all([first,second]);assert.equal(actions,2);
 assert.equal(run("deferredExportAction(action,'excel')()"),3,'loaded tools execute synchronously');
 delete sandbox.XLSX;run('exportScriptRequests.clear()');
 const waiting=run("deferredExportAction(action,'excel')()");
 run('state._accountEpoch++');sandbox.XLSX={};scripts.at(-1).onload();await waiting;
 assert.equal(actions,3,'account change cancels a waiting export');
 delete sandbox.XLSX;run('exportScriptRequests.clear();toast=()=>{};');
 const failure=run("deferredExportAction(action,'excel')()");scripts.at(-1).onerror();await failure;
 assert.equal(run('exportScriptRequests.size'),0,'failed script can be retried');
 const settingsRequests=[];
 sandbox.settingsQuery=()=>({select(){return this},eq(){return this},maybeSingle(){return new Promise(resolve=>settingsRequests.push(resolve))}});
 run("state.staff={id:'old-admin',role:'admin',business_id:'old-biz'};sb.from=settingsQuery;");
 const settings=run('loadSettings()'),billing=run('loadBillingStatus({silent:true})');
 assert.equal(settingsRequests.length,2,'startup configuration requests run independently');
 run("state._accountEpoch++;state.staff={id:'new-admin',role:'admin',business_id:'new-biz'};state.settings={marker:'new'};state.billing={marker:'new'};");
 settingsRequests.forEach(resolve=>resolve({data:{business_name:'old'},error:null}));
 await Promise.all([settings,billing]);
 assert.equal(run('state.settings.marker'),'new');assert.equal(run('state.billing.marker'),'new','late responses cannot overwrite a new account');
 let ledgerRepairs=0;
 sandbox.repairLedger=async()=>{ledgerRepairs++;return {data:[{id:'payment',loan_id:'loan',meeting_date:'2026-10-01',updated_at:'2026-10-02T00:00:00Z',status:'approved',amount:180,principal:144,interest:36}],error:null};};
 run(`state.staff={id:'admin',role:'admin',business_id:'biz'};
   state.data.loans=[{id:'loan',member_id:'member',status:'active',loan_value:800,total_payable:1000,weekly_installment:100,start_date:'2026-09-01'}];
   state.data.repayments=[{id:'payment',loan_id:'loan',meeting_date:'2026-10-01',updated_at:'2026-10-02T00:00:00Z',status:'approved',amount:100,principal:80,interest:20}];
   const metrics=WamamaFinance.metrics(state.data.loans[0],state.data.repayments,todayISO());
   const snapshot={version:1,authorized:true,complete:true,asOfDate:todayISO(),checkedAt:new Date().toISOString(),visibleLoanIds:['loan'],
     rows:[{...state.data.loans[0],...metrics,repaymentCount:1,repaymentUpdatedAt:'2026-10-02T00:00:00Z'}]};
   sb.rpc=async()=>({data:snapshot,error:null});persistPartialFinancialCache=async()=>{};fetchPagedBusinessRows=repairLedger;`);
 assert.equal(await run('refreshFinancialSnapshot()'),true);assert.equal(ledgerRepairs,0,'matching cached ledgers are not redownloaded');
 run('snapshot.rows[0].paid=180;snapshot.rows[0].principalPaid=144;snapshot.rows[0].interestPaid=36;');
 assert.equal(await run('refreshFinancialSnapshot()'),true);assert.equal(ledgerRepairs,1,'ledger mismatch still triggers authoritative repair');
 assert.equal(run('state.data.repayments[0].amount'),180);
 let verifyCalled=false,releaseAux;
 const aux=new Promise(resolve=>{releaseAux=resolve});
 sandbox.fetchStages=async tables=>{
   if(tables.includes('pb_guarantors')){assert.equal(verifyCalled,true,'verified dashboard precedes independent auxiliary history');await aux;}
   return tables.map(()=>({data:[],error:null}));
 };
 sandbox.verify=async()=>{verifyCalled=true;return true;};
 run(`state.staff={id:'admin',role:'admin',business_id:'biz'};state.session={user:{id:'auth'}};
 sb.auth.getSession=async()=>({data:{session:state.session},error:null});
 hydrateDataFromFinancialCache=async()=>0;render=()=>{};scheduleRealtimeRender=()=>{};
 loadOptimizedTablesWithLimit=fetchStages;loadInventoryReferencePrices=async()=>true;
 applySupervisorDataScope=()=>{};cacheDataKey=()=>{};refreshFinancialSnapshot=verify;
 refreshOfficerLoanDepositBalances=async()=>true;releaseDuePrepaymentsInBackground=()=>{};`);
 const loading=run('loadAllFinancialData()');await tick();await tick();
 assert.equal(verifyCalled,true);assert.equal(run('state._portfolioDataVerified'),true);
 run("state.view='purchases';renderPage()");assert.match(page.innerHTML,/Loading this section/);
 releaseAux();await loading;assert.equal(run('state._dataTablesLoading.size'),0);
 run("state._dataTableErrors.add('pb_purchases');renderPage()");assert.match(page.innerHTML,/Records could not be verified/);
 console.log('Export tools lazy-load once, retry failures, cancel after account switches; verified dashboard precedes auxiliary tabs; incomplete/error tabs are guarded.');
})().catch(e=>{console.error(e);process.exitCode=1;});
