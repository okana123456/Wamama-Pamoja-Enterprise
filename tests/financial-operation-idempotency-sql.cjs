// Idempotent meeting / repayment submissions against production-equivalent
// guards: the 30-second pending guard, the repeated-meeting receipt and saving
// guards installed on 18 Nov 2026, and one loan deposit per repayment.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const sql=f=>fs.readFileSync(path.join(__dirname,'..',f),'utf8');
const id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
const op=n=>`10000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
(async()=>{
const db=new PGlite();
await db.exec(`
create role anon; create role authenticated;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid',true),'')::uuid $$;
create table pb_staff(id uuid primary key,auth_user_id uuid,business_id text,role text,status text default 'active',full_name text);
create table pb_permissions(staff_id uuid,can_record_repayments boolean default false);
create table pb_groups(id uuid primary key,business_id text,name text,officer_id uuid);
create table pb_members(id uuid primary key,business_id text,group_id uuid,status text default 'active');
create table pb_loans(id uuid primary key,business_id text,member_id uuid,group_id uuid,status text,total_payable numeric,loan_value numeric,weekly_installment numeric);
create table pb_meetings(id uuid primary key default gen_random_uuid(),business_id text,group_id uuid,meeting_date date,recorded_by uuid,created_at timestamptz default now());
create table pb_savings(id uuid primary key default gen_random_uuid(),business_id text,member_id uuid,group_id uuid,meeting_id uuid,meeting_date date,amount numeric,recorded_by uuid,notes text,status text,created_at timestamptz default now(),updated_at timestamptz default now());
create table pb_repayments(id uuid primary key default gen_random_uuid(),business_id text,loan_id uuid,member_id uuid,group_id uuid,meeting_id uuid,meeting_date date,amount numeric,principal numeric,interest numeric,recorded_by uuid,status text,notes text,edit_notes text,voided_at timestamptz,created_at timestamptz default now(),updated_at timestamptz default now());
create table pb_excess_payments(id uuid primary key default gen_random_uuid(),business_id text,original_repayment_id uuid,source text,status text,original_payment_amount numeric,excess_amount numeric);
create unique index pb_excess_payments_original_repayment_uidx on pb_excess_payments(original_repayment_id) where original_repayment_id is not null;
-- Stand-in for pb_capture_repayment_excess: an approved payment above the
-- weekly instalment is held as one scheduled deposit.
create function capture_excess() returns trigger language plpgsql as $$
declare w numeric; begin
  select weekly_installment into w from pb_loans where id=new.loan_id;
  if lower(new.status)='approved' and new.amount>w then
    insert into pb_excess_payments(business_id,original_repayment_id,source,status,original_payment_amount,excess_amount)
    values(new.business_id,new.id,'scheduled_prepayment','pending',new.amount,new.amount-w);
  end if; return new; end $$;
create trigger zz_capture after insert or update of status on pb_repayments for each row execute function capture_excess();
`);
await db.exec(sql('wamama-repayment-workflow-safety.sql'));
await db.exec(sql('wamama-meeting-repayment-retry-guard.sql'));
await db.exec(sql('wamama-meeting-savings-retry-guard.sql'));
const migration=sql('wamama-financial-operation-idempotency.sql');
await db.exec(migration); await db.exec(migration); // re-runnable

const B1=id(1),B2=id(2),ADMIN=id(10),OFFICER=id(11),OTHER_BIZ=id(12),G=id(20),G2=id(21),M1=id(30),M2=id(31),L1=id(40),L2=id(41),L3=id(42);
await db.exec(`
insert into pb_staff values('${ADMIN}','${id(100)}','${B1}','admin','active','Admin'),('${OFFICER}','${id(101)}','${B1}','loan_officer','active','Officer'),('${OTHER_BIZ}','${id(102)}','${B2}','admin','active','Other');
insert into pb_groups values('${G}','${B1}','Group','${OFFICER}'),('${G2}','${B2}','Other group',null);
insert into pb_members values('${M1}','${B1}','${G}'),('${M2}','${B1}','${G}');
insert into pb_loans values('${L1}','${B1}','${M1}','${G}','active',1200,1000,100),('${L2}','${B1}','${M2}','${G}','active',1200,1000,100),('${L3}','${B1}','${M2}','${G}','closed',1200,1000,100);`);
const as=async(staffAuthId,fn)=>{await db.exec(`select set_config('test.uid','${staffAuthId}',false)`);return fn();};
const submit=async(auth,payload)=>(await as(auth,()=>db.query('select pb_submit_meeting($1::jsonb) r',[JSON.stringify(payload)]))).rows[0].r;
const count=async(t,where='true')=>(await db.query(`select count(*)::int n from ${t} where ${where}`)).rows[0].n;

const meeting={operation_id:op(1),group_id:G,meeting_date:'2026-11-17',
  savings:[{client_operation_id:op(2),member_id:M1,amount:100},{client_operation_id:op(3),member_id:M2,amount:50}],
  repayments:[{client_operation_id:op(4),loan_id:L1,amount:200},{client_operation_id:op(5),loan_id:L2,amount:100},{client_operation_id:op(6),loan_id:L3,amount:100}]};

// First request: closed loan fails, everything else saved. Partial success.
let r=await submit(id(100),meeting);
assert.equal(r.meeting.state,'created');
assert.deepEqual(r.savings.map(x=>x.state),['created','created']);
assert.deepEqual(r.repayments.map(x=>x.state),['created','created','failed']);
assert.equal(await count('pb_excess_payments'),1,'one deposit for the advance payment');

// Lost response then retry, five more times (double clicks, timeouts, reloads).
for(let i=0;i<5;i++){
  r=await submit(id(100),meeting);
  assert.equal(r.meeting.state,'existing');
  assert.deepEqual(r.savings.map(x=>x.state),['existing','existing']);
  assert.deepEqual(r.repayments.map(x=>x.state),['existing','existing','failed']);
}
assert.equal(await count('pb_meetings'),1);
assert.equal(await count('pb_savings'),2);
assert.equal(await count('pb_repayments'),2);
assert.equal(await count('pb_excess_payments'),1,'retries never recognise cash twice');

// Retry after the receipt was converted into a held deposit (status rejected
// with the held note) and after approval of the saving.
await db.exec(`update pb_repayments set status='rejected',edit_notes='Full amount held in loan prepayment account until scheduled instalments become due.' where loan_id='${L1}';
update pb_savings set status='approved'`);
r=await submit(id(100),meeting);
assert.equal(r.repayments[0].state,'existing');
assert.equal(r.repayments[0].row.status,'rejected');
assert.equal(await count('pb_repayments'),2);

// Reusing an operation ID with different money is refused, not silently merged.
r=await submit(id(100),{...meeting,savings:[{client_operation_id:op(2),member_id:M1,amount:150}],repayments:[{client_operation_id:op(4),loan_id:L1,amount:999}]});
assert.equal(r.savings[0].state,'failed');assert.match(r.savings[0].message,/OPERATION_MISMATCH/);
assert.equal(r.repayments[0].state,'failed');assert.match(r.repayments[0].message,/OPERATION_MISMATCH/);

// Fixing the failed entry and retrying creates only that entry.
await db.exec(`update pb_loans set status='active' where id='${L3}'`);
r=await submit(id(100),meeting);
assert.deepEqual(r.repayments.map(x=>x.state),['existing','existing','created']);
assert.equal(await count('pb_repayments'),3);

// A second device/tab with a NEW operation for the same meeting money is still
// caught by the repeated-meeting guard (defence for lost device storage).
r=await submit(id(100),{operation_id:op(7),group_id:G,meeting_date:'2026-11-17',savings:[{client_operation_id:op(8),member_id:M2,amount:50}],repayments:[{client_operation_id:op(9),loan_id:L2,amount:100}]});
assert.equal(r.meeting.state,'existing','same group and date reuse one meeting');
assert.equal(r.savings[0].state,'failed');assert.match(r.savings[0].message,/already recorded/);
assert.equal(r.repayments[0].state,'failed');assert.match(r.repayments[0].message,/already recorded/);

// Legitimate separate payments with the same date and amount (no meeting).
const batch=async(auth,rows)=>(await as(auth,()=>db.query('select pb_record_repayments_batch($1::jsonb) r',[JSON.stringify(rows)]))).rows[0].r;
let b=await batch(id(101),[{client_operation_id:op(20),loan_id:L2,amount:30,meeting_date:'2026-11-18'}]);
assert.equal(b.saved_count,1);assert.equal(b.rows[0].status,'pending');
b=await batch(id(101),[{client_operation_id:op(21),loan_id:L2,amount:30,meeting_date:'2026-11-18'}]);
assert.equal(b.saved_count,1,'a second genuine KES 30 payment is accepted');
b=await batch(id(101),[{client_operation_id:op(21),loan_id:L2,amount:30,meeting_date:'2026-11-18'}]);
assert.equal(b.saved_count,1);assert.equal(b.results[0].state,'existing','retry of the second payment returns it');
assert.equal(await count('pb_repayments',`meeting_date='2026-11-18'`),2);
// Retry after approval of a standalone payment.
await db.exec(`update pb_repayments set status='approved' where client_operation_id='${op(20)}'`);
b=await batch(id(101),[{client_operation_id:op(20),loan_id:L2,amount:30,meeting_date:'2026-11-18'}]);
assert.equal(b.results[0].state,'existing');assert.equal(await count('pb_repayments',`meeting_date='2026-11-18'`),2);
// Older browsers (no operation ID) keep the 30-second guard behaviour.
b=await batch(id(101),[{loan_id:L1,amount:40,meeting_date:'2026-11-19'}]);assert.equal(b.saved_count,1);
b=await batch(id(101),[{loan_id:L1,amount:40,meeting_date:'2026-11-19'}]);assert.equal(b.failed_count,1);

// A different signed-in account in the same business replaying the same ID
// gets the existing row, not a second receipt.
b=await batch(id(100),[{client_operation_id:op(21),loan_id:L2,amount:30,meeting_date:'2026-11-18'}]);
assert.equal(b.results[0].state,'existing');

// Cross-business isolation: another business cannot use this group or loan,
// and the same operation UUID in another business is independent.
await assert.rejects(submit(id(102),meeting),/group was not found in your business/);
b=await batch(id(102),[{client_operation_id:op(4),loan_id:L1,amount:200}]);
assert.equal(b.failed_count,1,'loan from another business is refused');
await db.exec(`insert into pb_members values('${id(32)}','${B2}','${G2}');insert into pb_loans values('${id(43)}','${B2}','${id(32)}','${G2}','active',1200,1000,100)`);
r=await submit(id(102),{operation_id:op(1),group_id:G2,meeting_date:'2026-11-17',savings:[{client_operation_id:op(2),member_id:id(32),amount:100}],repayments:[{client_operation_id:op(4),loan_id:id(43),amount:100}]});
assert.equal(r.savings[0].state,'created','same UUID in another business is independent');
assert.equal(r.repayments[0].state,'created');
// Another business's member cannot be used inside this business's meeting.
r=await submit(id(100),{operation_id:op(30),group_id:G,meeting_date:'2026-11-24',savings:[{client_operation_id:op(31),member_id:id(32),amount:10}],repayments:[]});
assert.equal(r.savings[0].state,'failed');

// The unique index also protects direct table inserts that carry an ID.
await assert.rejects(db.query(`insert into pb_savings(business_id,member_id,amount,status,client_operation_id) values('${B1}','${M1}',100,'pending','${op(2)}')`),/duplicate key|unique/);
// API roles cannot call the internal helpers directly.
const grants=(await db.query(`select has_function_privilege('authenticated','public.pb_record_saving_operation(text,text,text,text,jsonb)','execute') s,
  has_function_privilege('authenticated','public.pb_submit_meeting(jsonb)','execute') m,
  has_function_privilege('anon','public.pb_submit_meeting(jsonb)','execute') a`)).rows[0];
assert.deepEqual(grants,{s:false,m:true,a:false});
// Unauthenticated callers are refused.
await assert.rejects(submit('',meeting),/staff account could not be found/);
console.log('PASS: retries, lost responses, approval/held retries, mismatch, partial batch, guards, same-amount payments, cross-business, accounts, grants');
await db.close();
})().catch(e=>{console.error(e);process.exit(1);});
