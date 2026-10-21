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
(async()=>{
 let calls=0;
 sandbox.signup={data:{user:{id:'new-user'},session:null},error:null};
 sandbox.login={data:{user:{id:'new-user'},session:{user:{id:'new-user'}}},error:null};
 sandbox.rpc=async(name,args)=>{calls++;assert.equal(name,'pb_register_business_admin');assert.equal(args.p_auth_user_id,'new-user');return {error:null};};
 run(`authRedirectUrl=()=>'';loadStaff=async()=>true;afterLogin=async()=>{};
 sb.auth.signUp=async()=>signup;sb.auth.signInWithPassword=async()=>login;sb.rpc=rpc;`);
 const attempt=()=>run(`registerBusiness({businessName:'Fixture',adminName:'Owner',email:'owner@example.test',password:'fixture-password',key:BUSINESS_REGISTRATION_KEY})`);
 const confirmation=await attempt();assert.equal(confirmation.requiresEmailConfirmation,true);assert.equal(calls,0,'no anonymous provisioning');
 sandbox.signup={data:{},error:{message:'User already registered'}};
 const provisioned=await attempt();assert.equal(provisioned.signedIn,true);assert.equal(calls,1,'confirmed owner provisions while signed in');
 console.log('Registration waits for confirmation and authentication before provisioning.');
})().catch(e=>{console.error(e);process.exitCode=1;});
