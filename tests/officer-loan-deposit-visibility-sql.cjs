const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

(async()=>{
  const db=new PGlite();
  await db.exec(`
    create role anon;
    create role authenticated;
    create schema auth;
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
    $$;
    grant usage on schema public,auth to anon,authenticated;
    grant execute on function auth.uid() to anon,authenticated;
    create table public.pb_staff(
      id uuid primary key,business_id text,auth_user_id uuid,status text,role text,team_name text
    );
    create table public.pb_groups(
      id uuid primary key,business_id text,officer_id uuid
    );
    create table public.pb_members(
      id uuid primary key,business_id text,group_id uuid
    );
    create table public.pb_excess_payments(
      id uuid primary key,business_id text,member_id text,payment_date date,
      excess_amount numeric,released_amount numeric,status text
    );
    insert into public.pb_staff values
      ('00000000-0000-0000-0000-000000000011','biz-a','00000000-0000-0000-0000-000000000101','active','admin',null),
      ('00000000-0000-0000-0000-000000000012','biz-a','00000000-0000-0000-0000-000000000102','active','loan_officer','team-a'),
      ('00000000-0000-0000-0000-000000000013','biz-a','00000000-0000-0000-0000-000000000103','active','loan_officer','team-b'),
      ('00000000-0000-0000-0000-000000000014','biz-a','00000000-0000-0000-0000-000000000104','active','supervisor','team-a'),
      ('00000000-0000-0000-0000-000000000015','biz-b','00000000-0000-0000-0000-000000000105','active','admin',null),
      ('00000000-0000-0000-0000-000000000016','biz-a','00000000-0000-0000-0000-000000000106','inactive','loan_officer','team-a');
    insert into public.pb_groups values
      ('00000000-0000-0000-0000-000000000021','biz-a','00000000-0000-0000-0000-000000000012'),
      ('00000000-0000-0000-0000-000000000022','biz-a','00000000-0000-0000-0000-000000000013'),
      ('00000000-0000-0000-0000-000000000023','biz-b','00000000-0000-0000-0000-000000000015');
    insert into public.pb_members values
      ('00000000-0000-0000-0000-000000000031','biz-a','00000000-0000-0000-0000-000000000021'),
      ('00000000-0000-0000-0000-000000000032','biz-a','00000000-0000-0000-0000-000000000022'),
      ('00000000-0000-0000-0000-000000000033','biz-b','00000000-0000-0000-0000-000000000023');
    insert into public.pb_excess_payments values
      ('00000000-0000-0000-0000-000000000041','biz-a','00000000-0000-0000-0000-000000000031','2026-10-01',100,20,'pending'),
      ('00000000-0000-0000-0000-000000000042','biz-a','00000000-0000-0000-0000-000000000031','2026-10-02',50,0,'pending'),
      ('00000000-0000-0000-0000-000000000043','biz-a','00000000-0000-0000-0000-000000000031','2026-10-01',90,0,'refunded'),
      ('00000000-0000-0000-0000-000000000044','biz-a','00000000-0000-0000-0000-000000000032','2026-10-01',70,0,'pending'),
      ('00000000-0000-0000-0000-000000000045','biz-b','00000000-0000-0000-0000-000000000033','2026-10-01',800,0,'pending');
  `);
  const migration=fs.readFileSync(path.join(__dirname,'../wamama-officer-loan-deposit-visibility.sql'),'utf8');
  await db.exec(migration);
  await db.exec(migration);
  const runAs=async(user,role='authenticated')=>{
    await db.exec(`set request.jwt.claim.sub='${user}'; set role ${role}`);
    try{return (await db.query('select * from public.pb_visible_loan_deposit_balances()')).rows;}
    finally{await db.exec('reset role');}
  };
  const officer=await runAs('00000000-0000-0000-0000-000000000102');
  assert.equal(officer.length,2);
  assert.deepEqual(officer.map(row=>Number(row.available_amount)),[80,50]);
  assert.equal((await runAs('00000000-0000-0000-0000-000000000104')).length,2);
  assert.equal((await runAs('00000000-0000-0000-0000-000000000103')).length,1);
  assert.equal((await runAs('00000000-0000-0000-0000-000000000101')).length,3);
  assert.equal((await runAs('00000000-0000-0000-0000-000000000105')).length,1);
  await assert.rejects(runAs('00000000-0000-0000-0000-000000000106'));
  await assert.rejects(runAs('00000000-0000-0000-0000-000000000102','anon'));
  await db.exec(`update public.pb_groups set officer_id='00000000-0000-0000-0000-000000000013'
    where id='00000000-0000-0000-0000-000000000021'`);
  assert.equal((await runAs('00000000-0000-0000-0000-000000000102')).length,0);
  assert.equal((await runAs('00000000-0000-0000-0000-000000000103')).length,3);
  await db.close();
  console.log('Officer loan deposit totals and business, team, reassignment, inactive-user and anonymous scopes passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
