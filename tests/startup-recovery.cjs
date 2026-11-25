const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict'),path=require('path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const node={innerHTML:'',style:{},classList:{toggle(){},add(){},remove(){}}};let renders=0;
const sandbox={WamamaFinance:require('../financial-rules.js'),console:{...console,error(){}},Intl,Date,URL,Map,Set,Promise,AbortController,
window:{addEventListener(){}},document:{addEventListener(){},getElementById(){return node},querySelector(){return null},documentElement:node},navigator:{onLine:true},localStorage:{getItem(){return null},setItem(){},removeItem(){}},sessionStorage:{getItem(){return null},setItem(){},removeItem(){}},setInterval(){},setTimeout,clearTimeout,requestAnimationFrame(){},supabase:{createClient(){return {auth:{onAuthStateChange(){}}}}}};
vm.createContext(sandbox);vm.runInContext(code.slice(0,code.indexOf('(async function boot(){')),sandbox);const run=s=>vm.runInContext(s,sandbox);
(async()=>{
assert.match(html,/<div id="app"><main id="startup-loading"/);assert.ok(html.indexOf('id="startup-loading"')<html.indexOf('src="vendor/supabase'));
assert.doesNotMatch(html,/<script src="https:\/\/cdn.jsdelivr.net\/npm\/@supabase/);
assert.match(html,/media="print" onload="this.media='all'"/);
assert.ok(fs.statSync(path.join(__dirname,'../vendor/supabase-2.119.0.js')).size>100000);
run(`applyTheme=()=>{};checkAppRelease=()=>new Promise(()=>{});render=()=>{globalThis.rendered=(globalThis.rendered||0)+1};sb.auth.getSession=async()=>({data:{session:null},error:null});`);
await run(code.slice(code.indexOf('(async function boot(){')));assert.equal(sandbox.rendered,1,'login renders even if release check never responds');
run(`sb.auth.getSession=async()=>{throw new Error('Connection failed')}`);await run(code.slice(code.indexOf('(async function boot(){')));assert.match(node.innerHTML,/Connection interrupted/);assert.match(node.innerHTML,/Reload and try again/);
await assert.rejects(run('startupWithTimeout(new Promise(()=>{}),2)'),/timed out/);
assert.equal(await run('startupWithTimeout(Promise.resolve(42),50)'),42);
for(const match of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g))if(match[1].trim())new Function(match[1]);
console.log('PASS: visible initial screen, local auth dependency, nonblocking release check, failed-session recovery, bounded startup wait and script syntax');
})().catch(e=>{console.error(e);process.exit(1)});
