const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');

(async()=>{
  const db=new PGlite();
  const id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
  await db.exec(`
    create role authenticated;
    create role anon;
    create table pb_loans(id uuid primary key,business_id text,member_id uuid,
      group_id uuid,status text,total_payable numeric,loan_value numeric);
    create table pb_repayments(id uuid primary key default gen_random_uuid(),
      business_id text,loan_id uuid,member_id uuid,group_id uuid,meeting_date date,
      created_at timestamptz default now(),voided_at timestamptz,amount numeric,
      principal numeric,interest numeric,recorded_by uuid,status text,notes text);
    create table pb_excess_payments(id uuid primary key,business_id text,loan_id text,
      member_id text,original_repayment_id text,source text,status text,
      payment_date date,excess_amount numeric,released_amount numeric default 0,
      created_at timestamptz default now(),last_released_at timestamptz,
      resolution_reference text,resolved_at timestamptz,updated_at timestamptz);
    create or replace function pb_can_manage_excess_payments() returns boolean
      language sql as $$ select current_setting('app.test_allowed',true)='yes' $$;
    create or replace function pb_current_business_id_text() returns text
      language sql as $$ select 'biz'::text $$;
    create or replace function pb_current_staff_id_text() returns text
      language sql as $$ select '${id(9)}'::text $$;
    set app.test_allowed='yes';
  `);
  const sql=fs.readFileSync(path.join(__dirname,'../wamama-close-paid-loan-early.sql'),'utf8');
  await db.exec(sql);
  await db.exec(`
    insert into pb_loans values
      ('${id(1)}','biz','${id(101)}','${id(201)}','active',1000,800),
      ('${id(2)}','biz','${id(102)}','${id(202)}','active',1000,800),
      ('${id(3)}','biz','${id(103)}','${id(203)}','active',1000,800),
      ('${id(4)}','other','${id(104)}','${id(204)}','active',1000,800);
    insert into pb_repayments(id,business_id,loan_id,member_id,group_id,
      meeting_date,amount,principal,interest,recorded_by,status) values
      ('${id(11)}','biz','${id(1)}','${id(101)}','${id(201)}',current_date,300,240,60,'${id(8)}','approved'),
      ('${id(12)}','biz','${id(2)}','${id(102)}','${id(202)}',current_date,300,240,60,'${id(8)}','approved'),
      ('${id(13)}','biz','${id(3)}','${id(103)}','${id(203)}',current_date,1000,800,200,'${id(8)}','approved');
    insert into pb_excess_payments(id,business_id,loan_id,member_id,original_repayment_id,
      source,status,payment_date,excess_amount,released_amount) values
      ('${id(21)}','biz','${id(1)}','${id(101)}','${id(11)}','scheduled_prepayment','pending',current_date,800,0),
      ('${id(22)}','biz','${id(2)}','${id(102)}','${id(12)}','scheduled_prepayment','pending',current_date,600,0),
      ('${id(23)}','biz','${id(1)}','${id(102)}','${id(12)}','scheduled_prepayment','pending',current_date,200,0);
  `);
  let result=(await db.query(`select pb_close_paid_loan_early('${id(1)}') as outcome`)).rows[0].outcome;
  assert.equal(result.status,'completed');
  assert.equal(Number(result.applied_deposit),700);
  assert.equal((await db.query(`select status from pb_loans where id='${id(1)}'`)).rows[0].status,'completed');
  assert.equal(Number((await db.query(`select released_amount from pb_excess_payments where id='${id(21)}'`)).rows[0].released_amount),700);
  assert.equal(Number((await db.query(`select amount from pb_early_loan_closure_allocations where loan_id='${id(1)}'`)).rows[0].amount),700);
  assert.equal((await db.query(`select count(*)::int as n from pb_repayments where loan_id='${id(1)}'`)).rows[0].n,2);
  result=(await db.query(`select pb_close_paid_loan_early('${id(1)}') as outcome`)).rows[0].outcome;
  assert.equal(Number(result.applied_deposit),0,'retry does not apply the deposit twice');
  result=(await db.query(`select pb_close_paid_loan_early('${id(2)}') as outcome`)).rows[0].outcome;
  assert.equal(result.status,'insufficient');
  assert.equal(Number(result.cash_still_needed),100);
  assert.equal((await db.query(`select status from pb_loans where id='${id(2)}'`)).rows[0].status,'active');
  assert.equal(Number((await db.query(`select released_amount from pb_excess_payments where id='${id(22)}'`)).rows[0].released_amount),0);
  assert.equal(Number((await db.query(`select released_amount from pb_excess_payments where id='${id(23)}'`)).rows[0].released_amount),0,
    'another loan deposit cannot be used to close this loan');
  result=(await db.query(`select pb_close_paid_loan_early('${id(3)}') as outcome`)).rows[0].outcome;
  assert.equal(result.status,'completed','fully applied repayments close without a deposit');
  await assert.rejects(db.query(`select pb_close_paid_loan_early('${id(4)}')`),/not found for this business/);
  await db.exec("set app.test_allowed='no'");
  await assert.rejects(db.query(`select pb_close_paid_loan_early('${id(2)}')`),/authorized manager/);
  await db.close();
  console.log('Early paid-loan closure SQL checks passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
