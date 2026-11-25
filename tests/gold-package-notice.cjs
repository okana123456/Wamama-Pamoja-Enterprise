const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict'),path=require('path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const node={style:{},classList:{toggle(){},add(){},remove(){}},remove(){this.removed=true;}};
const sandbox={WamamaFinance:require('../financial-rules.js'),console,Intl,Date,URL,Map,Set,Promise,AbortController,
window:{addEventListener(){}},document:{addEventListener(){},getElementById(){return node},querySelector(){return null},documentElement:node},navigator:{onLine:true},localStorage:{getItem(){return null},setItem(){},removeItem(){}},sessionStorage:{getItem(){return null},setItem(){},removeItem(){}},setInterval(){},setTimeout(){return 1},clearTimeout(){},requestAnimationFrame(){},supabase:{createClient(){return {auth:{onAuthStateChange(){}}}}}};
vm.createContext(sandbox);vm.runInContext(code.slice(0,code.indexOf('(async function boot(){')),sandbox);
const run=s=>vm.runInContext(s,sandbox);
run(`state.staff={id:'admin',business_id:'b3462eea-1c92-4411-9507-fb6c0b31ba28',role:'admin'};state.view='dashboard';billingTodayParts=()=>({year:'2026',month:'11',day:25});`);
assert.equal(run('shouldShowGoldPackageNotice()'),false,'package notice stays paused during identity review');
run('GOLD_PACKAGE_NOTICE.enabled=true');
assert.equal(run('shouldShowGoldPackageNotice()'),true);const notice=run('renderGoldPackageNotice()');assert.match(notice,/KES 10,000/);assert.equal(run('MONTHLY_SUBSCRIPTION_AMOUNT'),6000);
run('dismissGoldPackageNotice()');assert.equal(run('shouldShowGoldPackageNotice()'),false);assert.equal(node.removed,true);
run('state._goldPackageNoticeDismissed=false');assert.equal(run('shouldShowGoldPackageNotice()'),true);
run("billingTodayParts=()=>({year:'2026',month:'11',day:30})");assert.equal(run('shouldShowGoldPackageNotice()'),true);
run("billingTodayParts=()=>({year:'2026',month:'12',day:1})");assert.equal(run('shouldShowGoldPackageNotice()'),false);
run("billingTodayParts=()=>({year:'2026',month:'11',day:24})");assert.equal(run('shouldShowGoldPackageNotice()'),false);
run("billingTodayParts=()=>({year:'2026',month:'11',day:25});state.staff.role='supervisor'");assert.equal(run('renderGoldPackageNotice()'),'');
run("state.staff.role='admin';state.staff.business_id='other'");assert.equal(run('renderGoldPackageNotice()'),'');
run("state.staff.business_id='b3462eea-1c92-4411-9507-fb6c0b31ba28';state.view='reports'");assert.equal(run('renderGoldPackageNotice()'),'');
run("state.view='dashboard';modal=(options)=>{globalThis.packageOptions=options};showGoldPackageDetails()");assert.match(sandbox.packageOptions.body,/5,000 retained client records/);assert.match(sandbox.packageOptions.body,/1 December 2026/);
assert.match(code,/async function afterLogin\(offline\)\{\s*state\._goldPackageNoticeDismissed=false/);
const css=html.match(/<style>([\s\S]*?)<\/style>/)[1];
const preview=`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Gold package notification preview</title><style>${css}body{margin:0;background:#fffaf5;font-family:Arial,sans-serif}.preview-header{background:#fff;padding:22px 26px;border-bottom:1px solid #f1d9bd;font-weight:700}.preview-main{padding:30px;max-width:1100px}.preview-label{font-size:13px;color:#8a6a3c}.preview-kpis{display:flex;gap:16px;flex-wrap:wrap;margin-top:24px}.preview-kpi{background:#fff;border:1px solid #ecdcc6;border-radius:12px;padding:22px;min-width:160px}.preview-kpi strong{display:block;font-size:25px;margin-top:10px}dialog{max-width:520px;border:1px solid #d4af55;border-radius:16px;padding:26px}dialog::backdrop{background:#0005}</style><header class="preview-header">Wamama Pamoja Enterprise <span style="float:right;color:#8a6a3c;font-size:12px">Administrator dashboard</span></header><main class="preview-main"><div class="preview-label">DESIGN PREVIEW · SAMPLE FIGURES</div><h1>Operational overview</h1><p>Your portfolio at a glance.</p><div class="preview-kpis"><div class="preview-kpi">Members<strong>2,009</strong></div><div class="preview-kpi">Support package<strong>Gold</strong></div></div></main>${notice}<dialog id="package"><h2>Gold Support Package</h2>${sandbox.packageOptions.body}<button class="gold-package-view" onclick="document.getElementById('package').close()">Close</button></dialog><script>function dismissGoldPackageNotice(){document.getElementById('gold-package-notice').remove()}function showGoldPackageDetails(){document.getElementById('package').showModal()}</script></html>`;
// A paused production notice must not replace the separately prepared design preview.
console.log('PASS: admin/business scope, dates, dismissal, login reset, details, current price unchanged; preview generated');
