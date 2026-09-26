// Run with PGLITE_MODULE pointing to an installed @electric-sql/pglite module.
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const rules=require('../financial-rules.js');
(async()=>{
  const db=new PGlite();
  await db.exec(`create role anon;create role authenticated;create schema auth;
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    grant usage on schema public,auth to authenticated;
    create table pb_staff(id uuid primary key,auth_user_id uuid,business_id uuid,role text,status text,team_name text,full_name text);
    create table pb_groups(id uuid primary key,business_id uuid,officer_id uuid,updated_at timestamptz default now());
    create table pb_members(id uuid primary key,business_id uuid,group_id text,updated_at timestamptz default now());
    create table pb_loans(id uuid primary key,business_id uuid,member_id uuid,group_id uuid,officer_id uuid,status text,loan_value numeric,total_payable numeric,weekly_installment numeric,start_date date,updated_at timestamptz default now());
    create table pb_repayments(id uuid primary key,business_id uuid,loan_id uuid,group_id uuid,recorded_by uuid,status text,voided_at timestamptz,meeting_date date,created_at timestamptz default now(),updated_at timestamptz default now(),amount numeric,principal numeric,interest numeric,notes text);
    create table pb_excess_payments(id text primary key,business_id text,original_repayment_id text,original_payment_amount numeric,source text,status text,created_at timestamptz default now());
    grant select on all tables in schema public to authenticated;
    create function pb_reconcile_paid_loan(p_id text) returns numeric language sql as $$select sum(r.amount) from public.pb_repayments r where r.loan_id::text=p_id and r.status='approved'$$;
    create function pb_capture_repayment_excess() returns trigger language plpgsql as $$begin perform sum(r.amount) from public.pb_repayments r where r.loan_id=new.loan_id;return new;end$$;
    create function pb_release_due_prepayments() returns numeric language sql as $$select sum(r.amount) from public.pb_repayments r where r.loan_id is not null and r.status='approved'$$;`);
  const sql=fs.readFileSync(path.join(__dirname,'../wamama-authoritative-financial-snapshot.sql'),'utf8');
  const id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
  const insert=async(table,row)=>{const keys=Object.keys(row);await db.query(`insert into ${table}(${keys.join(',')}) values (${keys.map((_,i)=>'$'+(i+1)).join(',')})`,Object.values(row));};
  const biz='b3462eea-1c92-4411-9507-fb6c0b31ba28',otherBiz=id(2),admin=id(3),old=id(4),owner=id(5),supervisor=id(6),outsider=id(7);
  for(const [staff,role,business,team] of [[admin,'admin',biz,''],[old,'loan_officer',biz,'old'],[owner,'loan_officer',biz,'north'],[supervisor,'supervisor',biz,'north'],[outsider,'admin',otherBiz,'']])
    await insert('pb_staff',{id:staff,auth_user_id:staff,business_id:business,role,status:'active',team_name:team,full_name:role+' '+staff});
  await db.exec(sql);
  await db.exec(sql); // repeatable installation
  await insert('pb_groups',{id:id(10),business_id:biz,officer_id:owner});
  await insert('pb_groups',{id:id(11),business_id:otherBiz,officer_id:outsider});
  await insert('pb_members',{id:id(20),business_id:biz,group_id:id(10)});
  await insert('pb_members',{id:id(21),business_id:otherBiz,group_id:id(11)});
  const date=(await db.query(`select (now() at time zone 'Africa/Nairobi')::date::text as d`)).rows[0].d;
  const start=new Date(Date.parse(date+'T00:00:00Z')-8*86400000).toISOString().slice(0,10);
  const loan={id:id(30),business_id:biz,member_id:id(20),group_id:id(10),officer_id:old,status:'active',loan_value:800,total_payable:1000,weekly_installment:100,start_date:start};
  await insert('pb_loans',loan);
  await insert('pb_loans',{...loan,id:id(31),business_id:otherBiz,member_id:id(21),group_id:id(11),officer_id:outsider});
  await insert('pb_loans',{...loan,id:id(32),start_date:date});
  await insert('pb_loans',{...loan,id:id(33),start_date:null});
  const repayments=[];
  for(const [n,status,amount,voided,notes] of [[40,'approved',100,null,null],[41,'approved',900,date,null],[42,'pending',300,null,null],[43,'rejected',300,null,null],[44,'approved',50,null,'Scheduled prepayment release: test']]){
    const repayment={id:id(n),business_id:biz,loan_id:loan.id,group_id:id(10),recorded_by:owner,status,amount,principal:amount*.8,interest:amount*.2,voided_at:voided,meeting_date:start,notes};
    repayments.push(repayment);await insert('pb_repayments',repayment);
  }
  async function snapshot(staff,ids=null,since=null){
    await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[staff]);
    await db.exec('set role authenticated');
    try{return (await db.query('select pb_financial_snapshot($1,$2) as result',[ids,since])).rows[0].result;}
    finally{await db.exec('reset role');}
  }
  const management=await snapshot(admin),officer=await snapshot(owner),team=await snapshot(supervisor);
  assert.deepEqual(management.rows,officer.rows,'same portfolio and amounts for admin and current officer');
  assert.deepEqual(team.rows,officer.rows,'supervisor sees same team portfolio');
  assert.equal((await snapshot(old)).rows.length,0,'former assignment does not retain portfolio');
  assert.equal((await snapshot(outsider)).rows.length,1,'tenant isolation');
  assert.equal((await snapshot(id(99))).authorized,false,'unprovisioned caller');
  const got=management.rows.find(row=>row.id===loan.id),expected=rules.metrics(loan,repayments,date);
  for(const key of ['paid','principalPaid','interestPaid','outstandingPI','outstandingPrincipal','amountDue','arrears','nextDueDate']) assert.equal(got[key],expected[key],key);
  assert.equal(management.rows.find(row=>row.id===id(32)).arrears,0,'due today');
  assert.equal(management.rows.find(row=>row.id===id(32)).nextDueDate,date,'first instalment due today');
  assert.equal(management.rows.find(row=>row.id===id(33)).arrears,0,'missing date');
  assert.equal((await snapshot(owner,[loan.id])).rows.length,1,'targeted low-egress refresh');
  assert.equal((await snapshot(owner,null,new Date(Date.now()+60000).toISOString())).rows.length,0,'unchanged loans omitted');
  assert.equal(Number((await db.query('select pb_reconcile_paid_loan($1) as paid',[loan.id])).rows[0].paid),150,'deployed closure sum excludes voids');
  await insert('pb_excess_payments',{id:'deposit',business_id:biz,original_repayment_id:id(40),original_payment_amount:400,source:'scheduled_prepayment',status:'pending'});
  // The officer cannot read the raw deposit ledger, but can read authorized cash totals.
  await db.exec('revoke select on pb_excess_payments from authenticated');
  async function cashTotals(staff){
    await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[staff]);await db.exec('set role authenticated');
    try{return (await db.query('select pb_cash_collection_totals($1,$2) as result',[start,date])).rows[0].result;}
    finally{await db.exec('reset role');}
  }
  assert.deepEqual((await cashTotals(admin)).rows,(await cashTotals(owner)).rows,'cash parity despite restricted deposit access');
  assert.equal((await cashTotals(owner)).rows[0].amount,400,'original cash counted once; generated release excluded');
  assert.equal((await cashTotals(owner)).rows[0].interest,20,'release is not new interest collected');
  assert.equal((await cashTotals(outsider)).rows.length,0,'cash tenant isolation');
  // A transferred-away or deleted loan leaves the cached officer scope even in a delta response.
  await db.query('update pb_groups set officer_id=$1 where id=$2',[old,id(10)]);
  assert.equal((await snapshot(owner,null,new Date(Date.now()+60000).toISOString())).visibleLoanIds.length,0);
  const audit=await db.query(fs.readFileSync(path.join(__dirname,'../wamama-live-financial-reconciliation-check.sql'),'utf8'));
  assert.equal(audit.rows[0].snapshot_ready,true);
  assert.equal(Number(audit.rows[0].outstanding_including_interest),2850);
  assert.equal(Number(audit.rows[0].invalid_schedule_review),1);
  await db.exec('alter table pb_members add column full_name text;alter table pb_loans add column asset_name text');
  await insert('pb_loans',{...loan,id:id(34),status:'completed'});
  const completedReview=await db.query(fs.readFileSync(path.join(__dirname,'../wamama-completed-loan-review.sql'),'utf8'));
  assert.equal(completedReview.rows.length,1);
  assert.equal(completedReview.rows[0].loan_id,id(34));
  assert.equal(Number(completedReview.rows[0].remaining_balance),1000);
  assert.equal((await db.query('select status from pb_loans where id=$1',[id(34)])).rows[0].status,'completed','review never changes loan status');
  await db.exec(`alter table pb_excess_payments add column loan_id uuid;
    alter table pb_excess_payments add column excess_amount numeric;
    alter table pb_excess_payments add column released_amount numeric;
    create table pb_audit_log(id uuid primary key,business_id uuid,entity_id text,staff_name text,
      action text,old_value jsonb,new_value jsonb,created_at timestamptz default now())`);
  await db.query('update pb_loans set asset_name=$1 where id in ($2,$3,$4)',['Historical asset',id(30),id(31),id(34)]);
  await insert('pb_excess_payments',{id:'historical-deposit',business_id:biz,loan_id:id(34),source:'scheduled_prepayment',status:'pending',excess_amount:1000,released_amount:0});
  await insert('pb_audit_log',{id:id(60),business_id:biz,entity_id:id(34),staff_name:'Reviewer',action:'loan_update',old_value:{status:'active'},new_value:{status:'completed',reason:'Historical completion'}});
  const history=await db.query(fs.readFileSync(path.join(__dirname,'../wamama-completed-loan-history-check.sql'),'utf8'));
  assert.equal(history.rows.length,1);
  assert.equal(Number(history.rows[0].possible_replacements),1,'same member and asset; different business and different assets excluded');
  assert.equal(history.rows[0].possible_replacement_details[0].loan_id,id(30));
  assert.equal(Number(history.rows[0].available_deposit_on_this_loan),1000);
  assert.equal(history.rows[0].latest_loan_actions[0].new_status,'completed');
  assert.equal(history.rows[0].latest_loan_actions[0].reason,'Historical completion');
  assert.equal((await db.query('select status from pb_loans where id=$1',[id(34)])).rows[0].status,'completed','history check never reopens a loan');
  console.log('PostgreSQL migration, role parity, tenant boundaries, delta refresh and JS/SQL money parity passed.');
  await db.close();
})().catch(error=>{console.error(error);process.exitCode=1;});
