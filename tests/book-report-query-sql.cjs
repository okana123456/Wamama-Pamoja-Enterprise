const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
(async()=>{
  const db=new PGlite();
  const id=n=>'00000000-0000-0000-0000-'+String(n).padStart(12,'0');
  await db.exec(`
    create role anon;create role authenticated;create schema auth;
    create function auth.uid() returns uuid language sql as $$select nullif(current_setting('test.actor',true),'')::uuid$$;
    create table pb_staff(id uuid,business_id text,auth_user_id uuid,full_name text,role text,status text,team_name text);
    create table pb_members(id uuid,business_id text,group_id uuid);
    create table pb_groups(id uuid,business_id text,officer_id uuid);
    create table pb_loans(id uuid,business_id text,member_id uuid,group_id uuid,officer_id uuid);
    create table pb_repayments(id uuid,business_id text,member_id uuid,loan_id uuid,group_id uuid,amount numeric,interest numeric,status text,voided_at timestamptz,meeting_date date,created_at timestamptz,notes text);
    create table pb_savings(id uuid,business_id text,member_id uuid,group_id uuid,amount numeric,status text,voided_at timestamptz,meeting_date date,created_at timestamptz);
    create table pb_excess_payments(id uuid,business_id text,original_repayment_id text,original_payment_amount numeric,status text,source text,created_at timestamptz);
    insert into pb_staff values
      ('${id(1)}','biz','${id(1)}','Admin','admin','active',null),
      ('${id(2)}','biz','${id(2)}','Officer A','loan_officer','active','A'),
      ('${id(3)}','biz','${id(3)}','Officer B','loan_officer','active','B'),
      ('${id(4)}','biz','${id(4)}','Supervisor B','supervisor','active','B'),
      ('${id(5)}','foreign','${id(5)}','Other admin','admin','active',null);
    insert into pb_groups values('${id(10)}','biz','${id(2)}'),('${id(11)}','biz','${id(3)}');
    insert into pb_members values('${id(20)}','biz','${id(11)}');
    insert into pb_loans values('${id(30)}','biz','${id(20)}','${id(10)}','${id(2)}');
    insert into pb_repayments values
      ('${id(40)}','biz','${id(20)}','${id(30)}','${id(10)}',100,20,'approved',null,'2026-11-01',now(),null),
      ('${id(41)}','biz','${id(20)}','${id(30)}','${id(10)}',0,0,'rejected',null,'2026-11-02',now(),null),
      ('${id(42)}','biz','${id(20)}','${id(30)}','${id(10)}',100,20,'approved',null,'2026-11-03',now(),'Scheduled prepayment release: test'),
      ('${id(43)}','biz','${id(20)}','${id(30)}','${id(10)}',100,20,'approved',null,'2026-11-03',now(),'Auto-deducted test'),
      ('${id(44)}','biz','${id(20)}','${id(30)}','${id(10)}',100,20,'approved',now(),'2026-11-03',now(),null),
      ('${id(45)}','biz','${id(20)}','${id(30)}','${id(10)}',100,20,'pending',null,'2026-11-03',now(),null);
    insert into pb_excess_payments values
      ('${id(50)}','biz','${id(41)}',120,'pending','scheduled_prepayment','2026-11-02'),
      ('${id(51)}','biz','${id(41)}',999,'pending','scheduled_prepayment','2026-11-03'),
      ('${id(52)}','foreign','${id(40)}',999,'pending','scheduled_prepayment','2026-11-01');
    insert into pb_savings values
      ('${id(60)}','biz','${id(20)}','${id(10)}',50,'approved',null,'2026-11-01',now()),
      ('${id(61)}','biz','${id(20)}','${id(10)}',500,'pending',null,'2026-11-01',now()),
      ('${id(62)}','biz','${id(20)}','${id(10)}',500,'approved',now(),'2026-11-01',now());
  `);
  const fetchReport=async actor=>{
    await db.query("select set_config('test.actor',$1,false)",[actor||'']);
    const result=(await db.query("select pb_officer_book_activity('2026-11-01','2026-11-30') result")).rows[0].result;
    delete result.checkedAt;
    result.rows.sort((a,b)=>String(a.officerId).localeCompare(String(b.officerId))||String(a.groupId).localeCompare(String(b.groupId)));
    return result;
  };
  const actors=[id(1),id(2),id(3),id(4),id(5),null];
  await db.exec(fs.readFileSync(path.join(__dirname,'../wamama-officer-book-activity.sql'),'utf8'));
  const original=[];
  for(const actor of actors)original.push(await fetchReport(actor));
  await db.exec(fs.readFileSync(path.join(__dirname,'../wamama-officer-book-reporting-repair.sql'),'utf8'));
  for(let index=0;index<actors.length;index++)assert.deepEqual(await fetchReport(actors[index]),original[index]);
  const report=await fetchReport(id(1));
  assert.equal(report.rows[0].collections,220);
  assert.equal(report.rows[0].savings,50);
  assert.equal(report.rows[0].officerId,id(3));
  assert.equal((await db.query("select has_function_privilege('anon','public.pb_officer_book_activity(date,date)','execute') ok")).rows[0].ok,false);
  console.log('Optimized book report matches original totals and scope for admin, officers, supervisor, foreign business and signed-out callers.');
  await db.close();
})().catch(error=>{console.error(error);process.exit(1)});
