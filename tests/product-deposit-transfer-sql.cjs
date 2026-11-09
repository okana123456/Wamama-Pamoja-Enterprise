const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
(async()=>{const db=new PGlite();await db.exec(`
create role anon;create role authenticated;create schema auth;create function auth.uid() returns text language sql as $$select current_setting('test.actor',true)$$;
create table pb_staff(id text,business_id text,auth_user_id text,status text,role text);
create table pb_loans(id text,business_id text,member_id text,group_id text,status text,start_date date,weekly_installment numeric,total_payable numeric,loan_value numeric);
create table pb_excess_payments(id text,business_id text,member_id text,loan_id text,source text,status text,payment_date date,excess_amount numeric,released_amount numeric,last_released_at timestamptz,updated_at timestamptz,resolved_at timestamptz,resolution_reference text);
create table pb_repayments(id text default gen_random_uuid()::text,business_id text,loan_id text,member_id text,group_id text,meeting_date date,amount numeric,principal numeric,interest numeric,recorded_by text,status text,notes text,voided_at timestamptz,created_at timestamptz default now());
insert into pb_staff values('admin','biz','admin','active','admin'),('officer','biz','officer','active','loan_officer');
insert into pb_loans values('loan','biz','nancy','group','active',current_date,522.67,6272,5600);
insert into pb_excess_payments values('dep','biz','nancy',null,'pre_loan_deposit','pending',current_date,1300,0,null,null,null,null),('other','biz','different',null,'pre_loan_deposit','pending',current_date,1300,0,null,null,null,null);
insert into pb_repayments(business_id,loan_id,member_id,amount,status,meeting_date)values('biz','loan','nancy',333.61,'approved',current_date);
select set_config('test.actor','admin',false);
`);
await db.exec(fs.readFileSync(path.join(__dirname,'../wamama-authorized-product-deposit-transfer.sql'),'utf8'));
const call=(dep='dep',amount=189.06,request='nancy-transfer-test-1')=>db.query(`select pb_transfer_product_deposit_to_due_loan($1,'loan',$2,'Authorized test',$3) result`,[dep,amount,request]);
const result=(await call()).rows[0].result;assert.equal(Number(result.due_remaining),0);assert.equal(Number(result.deposit_remaining),1110.94);
assert.equal((await call()).rows[0].result.already_applied,true);
assert.equal((await db.query(`select count(*)::int n from pb_repayments where notes like 'Auto-deducted from pre-loan%'`)).rows[0].n,1);
await assert.rejects(call('other',1,'foreign-client-test-1'),/same client/);
await assert.rejects(call('dep',1,'above-due-test-001'),/already due/);
await assert.rejects(call('dep',189,'nancy-transfer-test-1'),/different instructions/);
await assert.rejects(db.query("delete from pb_repayments where notes like 'Auto-deducted from pre-loan%'"),/cannot be deleted/);
await assert.rejects(db.query("update pb_repayments set amount=1 where notes like 'Auto-deducted from pre-loan%'"),/cannot be edited/);
await db.exec(`select set_config('test.actor','officer',false)`);
await assert.rejects(call(),/Only an active administrator/);
assert.equal((await db.query(`select has_function_privilege('anon','public.pb_transfer_product_deposit_to_due_loan(text,text,numeric,text,text)','execute') ok`)).rows[0].ok,false);

await db.exec(`
  alter table pb_staff add column team_name text;
  alter table pb_excess_payments add column original_payment_amount numeric;
  alter table pb_excess_payments add column amount_applied_to_loan numeric;
  create table pb_members(id text,business_id text,group_id text);
  create table pb_groups(id text,business_id text,officer_id text);
  update pb_staff set team_name='Bongu' where id='officer';
  insert into pb_staff values ('sup','biz','sup','active','supervisor',' bongu '),
    ('other-officer','biz','other-officer','active','loan_officer','different'),
    ('foreign-owner','foreign-biz','foreign-owner','active','loan_officer','Bongu');
  insert into pb_groups values ('group','biz','officer'),
    ('outside','biz','other-officer'),('foreign-owner-group','biz','foreign-owner');
  insert into pb_members values ('nancy','biz','group'),('different','biz','outside');
  update pb_loans set weekly_installment=600 where id='loan';
  insert into pb_loans values ('outside-loan','biz','different','outside','active',current_date,200,400,300);
  select set_config('test.actor','sup',false);
`);
const supervisorSetup=fs.readFileSync(path.join(__dirname,'../wamama-supervisor-product-deposit-transfer.sql'),'utf8');
await db.exec(supervisorSetup);
await db.exec(supervisorSetup);
const list=async()=> (await db.query('select pb_supervisor_product_deposits() as rows')).rows[0].rows;
assert.deepEqual((await list()).map(row=>row.id),['dep']);
await assert.rejects(db.query("select pb_transfer_product_deposit_to_due_loan('other','outside-loan',1,'Out of scope','outside-scope-test-001')"),/assigned groups/);
await assert.rejects(call('other',1,'cross-member-test-002'),/same client/);
assert.equal(Number((await call('dep',77.33,'supervisor-transfer-001')).rows[0].result.due_remaining),0);
await db.exec("update pb_members set group_id='foreign-owner-group' where id='nancy'");
assert.deepEqual(await list(),[]);
await assert.rejects(call('dep',1,'reassigned-member-001'),/assigned groups/);
await db.exec("update pb_members set group_id='group' where id='nancy'; update pb_staff set team_name=null where id='sup'");
assert.deepEqual(await list(),[]);
await db.exec("update pb_groups set officer_id='sup' where id='group'");
assert.deepEqual((await list()).map(row=>row.id),['dep']);
await db.exec("update pb_staff set status='inactive' where id='sup'");
await assert.rejects(list(),/active supervisor/);
await assert.rejects(call('dep',1,'inactive-supervisor-001'),/Only an active/);
assert.equal((await db.query("select has_function_privilege('anon','public.pb_supervisor_product_deposits()','execute') as ok")).rows[0].ok,false);
console.log('Supervisor listing and transfers enforce current group ownership, business boundaries, active status and the amount due.');
console.log('Partial transfer clears due amount, preserves remainder, retries once, rejects officer/foreign-client/excess-due instructions and denies anonymous execution.');await db.close();})().catch(e=>{console.error(e);process.exit(1)});
