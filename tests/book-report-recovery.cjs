const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict'),path=require('path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const node={style:{},classList:{toggle(){},add(){},remove(){}}};
const sandbox={WamamaFinance:require('../financial-rules.js'),console,Intl,Date,URL,Map,Set,Promise,AbortController,
 window:{addEventListener(){}},document:{addEventListener(){},getElementById(){return node},querySelector(){return null},documentElement:node},
 navigator:{onLine:true},localStorage:{getItem(){return null},setItem(){},removeItem(){}},sessionStorage:{getItem(){return null},setItem(){},removeItem(){}},
 setInterval(){},setTimeout(){return 1},clearTimeout(){},requestAnimationFrame(){},
 supabase:{createClient(){return {auth:{onAuthStateChange(){}}}}}};
vm.createContext(sandbox);vm.runInContext(code.slice(0,code.indexOf('(async function boot(){')),sandbox);
const run=s=>vm.runInContext(s,sandbox);

(async()=>{
  run(`
    state.staff={id:'admin',business_id:'biz',role:'admin',app_role:'admin'};
    state.view='reports';
    state._portfolioDataVerified=true;
    state._financialSnapshotAvailable=false;
    ensureCashTotals=()=>true;
    sb.rpc=async()=>({data:null,error:{code:'57014',message:'canceling statement due to statement timeout'}});
  `);
  run('pageReports()');
  assert.match(node.innerHTML,/Monthly Client Recruitment/);
  assert.match(node.innerHTML,/Monthly Product Sales/);
  assert.doesNotMatch(node.innerHTML,/<h3>Officer performance<\/h3>/);
  await run('bookActivityRequests.get(cashSnapshotKey(reportDateRange()))');
  run('pageReports()');
  assert.match(node.innerHTML,/57014/);
  assert.match(node.innerHTML,/took too long/);
  assert.match(node.innerHTML,/Monthly Client Recruitment/);
  assert.doesNotMatch(node.innerHTML,/Please run the officer book reporting setup/);
  let writes=0;
  sandbox.XLSX={utils:{book_new(){return {}},json_to_sheet(){return {}},book_append_sheet(){}},writeFile(){writes++}};
  run("exportReport('management_summary')");
  assert.equal(writes,0,'failed book request cannot produce an incomplete management export');
  run(`
    sb.rpc=async()=>({data:{version:1,authorized:true,rows:[]},error:null});
    retryBookActivity();
  `);
  await run('bookActivityRequests.get(cashSnapshotKey(reportDateRange()))');
  run('pageReports()');
  assert.match(node.innerHTML,/<h3>Officer performance<\/h3>/);
  assert.equal(run('bookActivityErrors.size'),0);
  run(`
    bookActivitySnapshots.clear();
    sb.rpc=()=>new Promise(resolve=>globalThis.resolveOldBook=resolve);
    ensureBookActivity(reportDateRange(),{renderStatus:false});
    const oldBookPromise=bookActivityRequests.get(cashSnapshotKey(reportDateRange()));
    state._accountEpoch++;
    bookActivityRequests.clear();
    sb.rpc=()=>new Promise(resolve=>globalThis.resolveNewBook=resolve);
    ensureBookActivity(reportDateRange(),{renderStatus:false});
    resolveOldBook({data:{version:1,authorized:true,rows:[{officerId:'old'}]},error:null});
  `);
  await run('oldBookPromise');
  assert.equal(run('bookActivityRequests.size'),1,'an old request cannot delete the new session request');
  assert.equal(run('bookActivitySnapshots.size'),0,'old-session totals are discarded');
  run("resolveNewBook({data:{version:1,authorized:true,rows:[]},error:null})");
  await run('bookActivityRequests.get(cashSnapshotKey(reportDateRange()))');
  assert.equal(run('bookActivitySnapshots.size'),1);
  console.log('Book timeout keeps monthly reports available, prevents incomplete management exports, supports retry and discards prior-session responses.');
})().catch(error=>{console.error(error);process.exit(1)});
