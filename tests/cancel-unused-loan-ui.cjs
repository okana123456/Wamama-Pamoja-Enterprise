const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const script=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];new vm.Script(script);
const sandbox={WamamaFinance:require('../financial-rules.js'),console,Intl,Date,URL,Map,Set,Promise,
 window:{addEventListener(){}},document:{addEventListener(){},getElementById:id=>({value:id==='cancel-loan-reason'?'Created in error':''}),querySelector:()=>null},
 navigator:{onLine:true},localStorage:{getItem:()=>null,setItem(){},removeItem(){}},sessionStorage:{getItem:()=>null,setItem(){},removeItem(){}},
 setInterval(){},setTimeout(){return 1;},clearTimeout(){},requestAnimationFrame(){},
 supabase:{createClient:()=>({auth:{onAuthStateChange(){}}})}};
vm.createContext(sandbox);vm.runInContext(script.slice(0,script.indexOf('(async function boot(){')),sandbox);
const run=code=>vm.runInContext(code,sandbox);
run(`state.staff={id:'admin',role:'admin',app_role:'admin'};
 state.data.loans=[{id:'wrong',status:'active',member_id:'member',asset_name:'Nyumba',loan_value:19600}];
 state.data.repayments=[{id:'void',loan_id:'wrong',amount:800,voided_at:'2026-09-26'}];
 state.data.members=[{id:'member',full_name:'Client'}];
 modal=config=>{globalThis.cancelModal=config;};ensureFreshToken=async()=>true;closeModal=()=>{};
 persistPartialFinancialCache=async()=>{};pageLoans=()=>{globalThis.rendered=true;};
 toast=(message,kind)=>{globalThis.lastToast={message,kind};};
 refreshFinancialSnapshot=async ids=>{globalThis.refreshed=ids;return true;};`);
(async()=>{
 run(`sb.rpc=async(name,args)=>{globalThis.rpcCall={name,args};return {error:{message:'This loan has an active or pending payment.'}};};openCancelUnusedLoan(state.data.loans[0]);`);
 await run(`cancelModal.actions[1].onClick()`);
 assert.equal(run(`state.data.loans[0].status`),'active');
 assert.equal(sandbox.lastToast.kind,'error');
 run(`sb.rpc=async(name,args)=>{globalThis.rpcCall={name,args};return {data:{success:true,loan_id:'wrong',status:'cancelled'}};};`);
 await run(`cancelModal.actions[1].onClick()`);
 assert.equal(sandbox.rpcCall.name,'pb_cancel_unused_loan');
 assert.deepEqual(JSON.parse(JSON.stringify(sandbox.rpcCall.args)),{p_loan_id:'wrong',p_reason:'Created in error'});
 assert.equal(run(`state.data.loans[0].status`),'cancelled');
 assert.equal(run(`state.data.repayments.length`),1,'voided history remains');
 assert.equal(sandbox.refreshed[0],'wrong');
 // A late completion from a former account must not overwrite the current one.
 run(`state.data.loans[0].status='active';
  sb.rpc=async()=>{state._accountEpoch++;return {data:{success:true,loan_id:'wrong',status:'cancelled'}};};`);
 await run(`cancelModal.actions[1].onClick()`);
 assert.equal(run(`state.data.loans[0].status`),'active');
 run(`globalThis.cancelModal=null;state.staff={id:'officer',role:'officer',app_role:'loan_officer'};openCancelUnusedLoan(state.data.loans[0]);`);
 assert.equal(sandbox.cancelModal,null,'ordinary officers cannot use manager cancellation');
 // Every visible removal choice uses the same guarded server operation, including
 // duplicates and loans with retained voided history. No choice erases the ledger.
 run(`state.staff={id:'admin',role:'admin',app_role:'admin'};
  state.data.loans.push({...state.data.loans[0],id:'keep'});
  showActMenu=(event,items)=>{globalThis.loanMenu=items;};
  sb.from=()=>{throw Error('Removal must not directly delete loan records');};
  confirmDialog=()=>{throw Error('Removal must use the shared dialog');};
  loanActions({},'wrong');`);
 const removeLabels=['Cancel incorrect loan','⚠ Delete unused duplicate','🗑 Delete Loan'];
 for(const label of removeLabels){
  const action=sandbox.loanMenu.find(item=>item.label===label);
  assert.ok(action,`Missing removal option: ${label}`);
  run(`state.data.loans[0].status='active';
   sb.rpc=async(name,args)=>{globalThis.rpcCall={name,args};return {data:{success:true,loan_id:'wrong',status:'cancelled'}};};`);
  action.onClick();
  assert.equal(sandbox.cancelModal.title,'Remove incorrect loan');
  assert.equal(sandbox.cancelModal.actions[1].label,'Remove loan');
  await sandbox.cancelModal.actions[1].onClick();
  assert.equal(sandbox.rpcCall.name,'pb_cancel_unused_loan');
  assert.equal(sandbox.rpcCall.args.p_loan_id,'wrong');
  assert.equal(run(`state.data.loans[0].status`),'cancelled');
  assert.equal(run(`state.data.loans[1].status`),'active','the loan to keep is untouched');
  assert.equal(run(`state.data.repayments.length`),1,'voided history remains under every menu choice');
 }
 run(`state.data.loans[0].status='active';
  sb.rpc=async()=>({error:{message:'Could not find the function public.pb_cancel_unused_loan'}});
  openCancelUnusedLoan(state.data.loans[0]);`);
 await sandbox.cancelModal.actions[1].onClick();
 assert.equal(run(`state.data.loans[0].status`),'active','missing database setup cannot remove a loan locally');
 assert.match(sandbox.lastToast.message,/system update/);
 for(const role of ['loan_officer','officer','supervisor']){
  sandbox.testRole=role;
  run(`state.staff={id:'staff',role:testRole,app_role:testRole};loanActions({},'wrong');`);
  assert.ok(sandbox.loanMenu.every(item=>!removeLabels.includes(item.label)),`no unsupported removal for ${role}`);
 }
 console.log('Loan removal UI: all menu choices share server safeguards, preserve history and refresh only the selected loan.');
})().catch(error=>{console.error(error);process.exitCode=1;});
