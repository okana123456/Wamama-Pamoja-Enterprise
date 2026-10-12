const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');

(async()=>{
  const db=new PGlite();
  const id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
  await db.exec(`
    create role authenticated; create role anon;
    create table pb_loans(id uuid primary key,business_id text,member_id uuid,
      group_id uuid,status text,total_payable numeric,loan_value numeric,
      weekly_installment numeric,start_date date,expected_end_date date,
      created_at timestamptz default now());
    create table pb_repayments(id uuid primary key default gen_random_uuid(),
      business_id text,loan_id uuid,member_id uuid,group_id uuid,meeting_date date,
      created_at timestamptz default now(),voided_at timestamptz,amount numeric,
      principal numeric,interest numeric,recorded_by uuid,status text,notes text);
    create table pb_excess_payments(id uuid primary key,business_id text,member_id text,
      group_id text,loan_id text,original_repayment_id text,payment_date date,
      excess_amount numeric,released_amount numeric default 0,status text,source text,
      created_at timestamptz default now(),last_released_at timestamptz,
      resolution_reference text,resolved_at timestamptz,updated_at timestamptz);
    create table pb_prepayment_releases(id uuid primary key default gen_random_uuid(),
      business_id text,prepayment_id text,loan_id text,member_id text,
      due_date date,amount numeric,repayment_id text,unique(prepayment_id,loan_id,due_date));
    create function pb_current_business_id_text() returns text language sql
      as $$ select 'biz'::text $$;
  `);
  const sql=fs.readFileSync(path.join(__dirname,'../wamama-optimize-prepayment-release.sql'),'utf8');
  await db.exec(sql);
  await db.exec(`
    insert into pb_loans(id,business_id,member_id,group_id,status,total_payable,
      loan_value,weekly_installment,start_date,expected_end_date) values
      ('${id(1)}','biz','${id(101)}','${id(201)}','active',1000,800,100,
        (now() at time zone 'Africa/Nairobi')::date-14,
        (now() at time zone 'Africa/Nairobi')::date+70),
      ('${id(2)}','biz','${id(102)}','${id(202)}','active',1000,800,100,
        (now() at time zone 'Africa/Nairobi')::date-7,
        (now() at time zone 'Africa/Nairobi')::date+77);
    insert into pb_repayments(id,business_id,loan_id,member_id,group_id,
      meeting_date,amount,principal,interest,recorded_by,status) values
      ('${id(11)}','biz','${id(1)}','${id(101)}','${id(201)}',
        (now() at time zone 'Africa/Nairobi')::date,100,80,20,'${id(8)}','rejected'),
      ('${id(12)}','biz','${id(2)}','${id(102)}','${id(202)}',
        (now() at time zone 'Africa/Nairobi')::date-1,100,80,20,'${id(8)}','rejected');
    insert into pb_excess_payments(id,business_id,member_id,group_id,loan_id,
      original_repayment_id,payment_date,excess_amount,status,source) values
      ('${id(21)}','biz','${id(101)}','${id(201)}','${id(1)}','${id(11)}',
        (now() at time zone 'Africa/Nairobi')::date,100,'pending','scheduled_prepayment'),
      ('${id(22)}','biz','${id(102)}','${id(202)}','${id(2)}','${id(12)}',
        (now() at time zone 'Africa/Nairobi')::date-1,100,'pending','scheduled_prepayment');
  `);
  const result=(await db.query('select pb_release_due_prepayments(null,1) as count')).rows[0];
  assert.equal(result.count,1,'a future-only first loan cannot block a due second loan');
  const paid=(await db.query(`select loan_id::text as loan_id,amount,notes from pb_repayments
    where status='approved'`)).rows;
  assert.equal(paid.length,1);
  assert.equal(paid[0].loan_id,id(2));
  assert.equal(Number(paid[0].amount),100);
  assert.equal((await db.query('select pb_release_due_prepayments(null,1) as count')).rows[0].count,0,
    'already released cash is not applied twice');
  assert.equal(Number((await db.query(`select released_amount from pb_excess_payments
    where id='${id(21)}'`)).rows[0].released_amount),0);
  await db.close();
  console.log('Due prepayment release selects eligible loans and prevents double use.');
})().catch(error=>{console.error(error);process.exitCode=1;});
