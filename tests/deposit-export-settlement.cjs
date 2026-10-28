const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const html=fs.readFileSync(require('node:path').join(__dirname,'../index.html'),'utf8');
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const page={style:{},classList:{toggle(){},add(){},remove(){}}};
const sandbox={WamamaFinance:require('../financial-rules.js'),console,Intl,Date,URL,Map,Set,Promise,
 window:{addEventListener(){}},document:{addEventListener(){},getElementById(){return page},querySelector(){return null},documentElement:page},
 navigator:{onLine:true},localStorage:{getItem(){return null},setItem(){},removeItem(){}},sessionStorage:{getItem(){return null},setItem(){},removeItem(){}},
 setInterval(){},setTimeout(){return 1},clearTimeout(){},requestAnimationFrame(){},
 supabase:{createClient(){return {auth:{onAuthStateChange(){}}}}}};
vm.createContext(sandbox);vm.runInContext(code.slice(0,code.indexOf('(async function boot(){')),sandbox);
const run=s=>vm.runInContext(s,sandbox);
(async()=>{
 const events=[];let releases=[2,0];
 sandbox.rpc=async()=>{events.push('release');return {data:releases.shift()??0,error:null};};
 sandbox.snapshot=async()=>{events.push('snapshot');return true;};
 sandbox.ledger=async()=>{events.push('ledger');return {data:[{id:'deposit',released_amount:15.4,excess_amount:1171.6}],error:null};};
 run(`state.staff={id:'admin',role:'admin',business_id:'biz'};state.session={user:{id:'auth'}};
 state._financialSnapshotAvailable=true;sb.rpc=rpc;refreshFinancialSnapshot=snapshot;loadBusinessTableOptimized=ledger;toast=()=>{};`);
 assert.equal(await run('ensureOfficerLoanDepositsForExport()'),true);
 assert.deepEqual(events,['release','release','snapshot','ledger']);
 assert.equal(run('state.data.excessPayments[0].released_amount'),15.4);
 events.length=0;
 await Promise.all([run('settleScheduledLoanDeposits()'),run('settleScheduledLoanDeposits()')]);
 assert.equal(events.length,1,'simultaneous exports share the release request');
 run(`sb.rpc=async()=>({data:null,error:{message:'Cannot verify deposits'}});`);
 assert.equal(await run('ensureOfficerLoanDepositsForExport()'),false,'RPC failure blocks export');
 run(`sb.rpc=async()=>({data:0,error:null});loadBusinessTableOptimized=async()=>({data:[],stale:true,error:null});`);
 assert.equal(await run('ensureOfficerLoanDepositsForExport()'),false,'stale manager ledger blocks export');
 run(`sb.rpc=async()=>{state._accountEpoch++;return {data:0,error:null}};`);
 assert.equal(await run('ensureOfficerLoanDepositsForExport()'),false,'account change blocks export');
 console.log('Exports settle all batches before fresh balances/deposits; failures, stale ledgers and account switches stop export; parallel calls share settlement.');
})().catch(e=>{console.error(e);process.exitCode=1;});
