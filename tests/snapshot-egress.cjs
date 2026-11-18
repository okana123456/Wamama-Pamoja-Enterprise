// Lower-egress snapshot: v2 SQL wrapper behaviour (PGlite) and the browser's
// use of it (fingerprinted visible-loan list, changes-only merge, fallback).
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
(async()=>{
  // ---- SQL wrapper ----
  const db=new PGlite();
  await db.exec(`create role anon;create role authenticated;
    create function public.pb_financial_snapshot(p_loan_ids text[] default null,p_since timestamptz default null) returns jsonb
    language sql stable as $$ select jsonb_build_object('version',1,'authorized',true,'complete',p_loan_ids is null and p_since is null,
      'asOfDate','2026-11-18','visibleLoanIds',jsonb_build_array('a','b','c'),
      'rows',case when p_loan_ids is null then '[{"id":"a"},{"id":"b"},{"id":"c"}]'::jsonb else (select jsonb_agg(jsonb_build_object('id',x)) from unnest(p_loan_ids) x) end) $$;`);
  const sql=fs.readFileSync(path.join(__dirname,'../wamama-financial-snapshot-egress.sql'),'utf8');
  await db.exec(sql);await db.exec(sql);
  const full=(await db.query(`select pb_financial_snapshot_v2(null,null,true) j`)).rows[0].j;
  const lean=(await db.query(`select pb_financial_snapshot_v2(array['b'],null,false) j`)).rows[0].j;
  assert.deepEqual(full.visibleLoanIds,['a','b','c']);
  assert.equal(lean.visibleLoanIds,undefined,'list omitted on request');
  assert.equal(lean.visibleLoanIdsHash,full.visibleLoanIdsHash,'same fingerprint for the same list');
  assert.equal(lean.visibleLoanCount,3);assert.deepEqual(lean.rows,[{id:'b'}]);
  const grants=(await db.query(`select has_function_privilege('anon','public.pb_financial_snapshot_v2(text[],timestamptz,boolean)','execute') a,
    has_function_privilege('authenticated','public.pb_financial_snapshot_v2(text[],timestamptz,boolean)','execute') u`)).rows[0];
  assert.deepEqual(grants,{a:false,u:true});
  await db.close();

  // ---- Browser ----
  const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
  const code=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
  const calls=[];let v2Installed=true,ids=['a','b','c'],hash='h1';
  const sb={auth:{onAuthStateChange(){}},rpc(name,args){
    calls.push({name,args});
    const run=async()=>{
      if(name==='pb_financial_snapshot_v2' && !v2Installed) return {data:null,error:{code:'PGRST202',message:'Could not find the function'}};
      const complete=!args.p_loan_ids && !args.p_since;
      const rowIds=args.p_loan_ids||(args.p_since?['b']:ids);
      const data={version:1,authorized:true,complete,asOfDate:vm.runInContext('todayISO()',sandbox),checkedAt:new Date().toISOString(),
        rows:rowIds.map(id=>({id,group_id:'g1',officer_id:'o1',status:'active',paid:id==='b'?200:0,principalPaid:0,interestPaid:0,repaymentCount:0,outstandingPI:1000,outstandingPrincipal:800,arrears:0}))};
      if(name==='pb_financial_snapshot' || args.p_include_ids!==false) data.visibleLoanIds=ids;
      if(name==='pb_financial_snapshot_v2') Object.assign(data,{visibleLoanIdsHash:hash,includesVisibleLoanIds:args.p_include_ids!==false});
      return {data,error:null};
    };
    const p=run();p.abortSignal=()=>p;return p;},
    from(){const q={select(){return q},order(){return q},limit(){return q},eq(){return q},gt(){return q},in(){return q},then(r){return Promise.resolve({data:[],error:null}).then(r)}};return q;}};
  const el={innerHTML:'',style:{},classList:{toggle(){},add(){},remove(){}}};
  const sandbox={WamamaFinance:require('../financial-rules.js'),console,Intl,Date,URL,Map,Set,Promise,JSON,Math,
    window:{addEventListener(){}},document:{addEventListener(){},getElementById(){return el},querySelector(){return null},documentElement:el},
    navigator:{onLine:true},localStorage:{getItem(){return null},setItem(){},removeItem(){}},sessionStorage:{getItem(){return null},setItem(){},removeItem(){}},
    setTimeout,clearTimeout,setInterval(){},requestAnimationFrame(){},AbortController,supabase:{createClient(){return sb}}};
  vm.createContext(sandbox);vm.runInContext(code.slice(0,code.indexOf('(async function boot(){')),sandbox);
  const run=s=>vm.runInContext(s,sandbox);
  run(`persistPartialFinancialCache=async()=>{};state.staff={id:'admin',role:'admin',business_id:'biz'};
    state.data.groups=[{id:'g1',officer_id:'o1'}];state.data.repayments=[];
    state.data.loans=['a','b','c'].map(id=>({id,member_id:'m',status:'active',total_payable:1000,loan_value:800,weekly_installment:100}));`);

  // 1. First full snapshot asks for the list (no fingerprint known yet).
  assert.equal(await run('refreshFinancialSnapshot()'),true);
  assert.equal(calls.at(-1).name,'pb_financial_snapshot_v2');assert.equal(calls.at(-1).args.p_include_ids,true);
  assert.equal(run('state._financialSnapshot.visibleHash'),'h1');

  // 2. A targeted refresh after a payment omits the list (fingerprint matches).
  calls.length=0;
  assert.equal(await run(`refreshFinancialSnapshot(['b'])`),true);
  assert.equal(calls.length,1);assert.equal(calls[0].args.p_include_ids,false);
  assert.equal(run(`state._financialSnapshot.byLoan.get('b').paid`),200);
  assert.equal(run('state._financialSnapshot.byLoan.size'),3,'other loans kept');

  // 3. Fingerprint changed (loan reassigned): the list is fetched again and
  //    a newly visible loan gets its own server row.
  calls.length=0;ids=['a','b','c','d'];hash='h2';
  run(`state.data.loans.push({id:'d',member_id:'m',status:'active',total_payable:1000,loan_value:800,weekly_installment:100})`);
  assert.equal(await run(`refreshFinancialSnapshot(null,{incremental:true})`),true);
  assert.deepEqual(calls.map(c=>c.args.p_include_ids),[false,true,false],'lean try, full list, then gap fill');
  assert.deepEqual(calls[2].args.p_loan_ids,['d']);
  assert.equal(run(`state._financialSnapshot.byLoan.has('d')`),true);
  assert.equal(run(`state._financialSnapshot.visibleHash`),'h2');

  // 4. Provisional figures from a changes-only snapshot merge onto today's
  //    saved snapshot; without a saved snapshot they are refused.
  const base=run('state._financialSnapshot');
  sandbox.__lean={version:1,authorized:true,complete:false,asOfDate:run('todayISO()'),checkedAt:new Date().toISOString(),
    rows:[{id:'a',group_id:'g1',officer_id:'o1',status:'active',paid:300,outstandingPI:700}],visibleLoanIds:['a','b','c','d'],visibleLoanIdsHash:'h2'};
  sandbox.__base=base;
  run('state._portfolioDataVerified=false');
  assert.equal(run('applyProvisionalFinancialSnapshot(__lean,null)'),false,'no saved snapshot: refused');
  assert.equal(run('applyProvisionalFinancialSnapshot(__lean,__base)'),true);
  assert.equal(run(`state._financialSnapshot.byLoan.get('a').paid`),300);
  assert.equal(run(`state._financialSnapshot.byLoan.get('b').paid`),200,'unchanged loans from saved snapshot');

  // 5. Before the v2 SQL is installed the original function is used.
  run('financialSnapshotV2=true;state._financialSnapshot=null');v2Installed=false;calls.length=0;
  assert.equal(await run('refreshFinancialSnapshot()'),true);
  assert.deepEqual(calls.map(c=>c.name),['pb_financial_snapshot_v2','pb_financial_snapshot']);
  calls.length=0;await run(`refreshFinancialSnapshot(['b'])`);
  assert.deepEqual(calls.map(c=>c.name),['pb_financial_snapshot'],'falls back without retrying v2');
  console.log('PASS: v2 wrapper (omit list, stable fingerprint, grants); browser lean refresh, fingerprint change + gap fill, provisional merge, v1 fallback');
})().catch(e=>{console.error(e);process.exit(1);});
