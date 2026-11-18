// The background deposit-release check runs on the first load of the day and
// then at most every 3 hours per device; a failed run is retried next load.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const store=new Map(),calls=[];let fail=false;
const sb={auth:{onAuthStateChange(){}},rpc(name){calls.push(name);const p=Promise.resolve(fail?{data:null,error:{message:'timeout'}}:{data:0,error:null});p.abortSignal=()=>p;return p;}};
const el={innerHTML:'',style:{},classList:{toggle(){},add(){},remove(){}}};
const timers=[];
const sandbox={WamamaFinance:require('../financial-rules.js'),console:{...console,warn(){}},Intl,Date,URL,Map,Set,Promise,JSON,Math,
  window:{addEventListener(){}},document:{addEventListener(){},getElementById(){return el},querySelector(){return null},documentElement:el},
  navigator:{onLine:true},localStorage:{getItem:k=>store.has(k)?store.get(k):null,setItem:(k,v)=>store.set(k,String(v)),removeItem:k=>store.delete(k)},
  sessionStorage:{getItem(){return null},setItem(){},removeItem(){}},
  setTimeout:(fn)=>{timers.push(fn);return timers.length},clearTimeout(){},setInterval(){},requestAnimationFrame(){},AbortController,supabase:{createClient(){return sb}}};
vm.createContext(sandbox);vm.runInContext(code.slice(0,code.indexOf('(async function boot(){')),sandbox);
const run=s=>vm.runInContext(s,sandbox);
const fire=async()=>{while(timers.length) await timers.shift()();};
(async()=>{
  run(`state.staff={id:'a',role:'admin',business_id:'biz'};refreshOfficerLoanDepositBalances=async()=>{};scheduleFinancialSnapshotRefresh=()=>{};`);
  run('releaseDuePrepaymentsInBackground()');await fire();
  assert.equal(calls.length,1,'first load of the day runs the check');
  run('releaseDuePrepaymentsInBackground()');await fire();
  assert.equal(calls.length,1,'second load within 3 hours skips it');
  const key='pb_release_checked_biz';
  store.set(key,JSON.stringify({day:run('todayISO()'),at:Date.now()-4*60*60*1000}));
  run('releaseDuePrepaymentsInBackground()');await fire();
  assert.equal(calls.length,2,'runs again after 3 hours');
  store.set(key,JSON.stringify({day:'2000-01-01',at:Date.now()}));
  run('releaseDuePrepaymentsInBackground()');await fire();
  assert.equal(calls.length,3,'a new day always runs it');
  store.delete(key);fail=true;
  run('releaseDuePrepaymentsInBackground()');await fire();
  assert.equal(store.has(key),false,'a failed check is not recorded');
  fail=false;run('releaseDuePrepaymentsInBackground()');await fire();
  assert.equal(calls.length,5,'so the next load retries');
  console.log('PASS: daily first run, 3-hour spacing, new day, retry after failure');
})().catch(e=>{console.error(e);process.exit(1);});
