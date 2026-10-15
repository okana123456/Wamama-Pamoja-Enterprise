const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
(async()=>{
 const db=new PGlite();
 await db.exec(`create role anon;create role authenticated;create schema auth;
 create function auth.uid() returns text language sql as $$ select current_setting('request.jwt.claim.sub',true) $$;
 create table pb_staff(id text,business_id text,auth_user_id text,role text,status text,team_name text);
 create table pb_groups(id text,business_id text,officer_id text);
 create table pb_members(id text,business_id text,group_id text);
 create table pb_loans(id text,business_id text,officer_id text,group_id text);
 create table pb_repayments(id text,business_id text,recorded_by text,member_id text,loan_id text,group_id text,meeting_date date,created_at timestamptz,voided_at timestamptz,status text,amount numeric,interest numeric,notes text);
 create table pb_savings(id text,business_id text,recorded_by text,member_id text,group_id text,meeting_date date,created_at timestamptz,status text,amount numeric);
 create table pb_excess_payments(id text,business_id text,original_repayment_id text,source text,created_at timestamptz,status text,original_payment_amount numeric);
 insert into pb_staff values('admin','biz','admin','admin','active',''),('esther','biz','esther','loan_officer','active','north'),
 ('david','biz','david','loan_officer','active','south'),('boss','biz','boss','supervisor','active','north'),('outside','other','outside','admin','active','');
 insert into pb_groups values('g','biz','esther'),('old','biz','david'),('other','other','outside');
 insert into pb_members values('m','biz','g'),('x','other','other');
 insert into pb_loans values('l','biz','david','old');`);
 const sql=fs.readFileSync(path.join(__dirname,'../wamama-officer-book-activity.sql'),'utf8');
 await db.exec(sql);await db.exec(sql);
 for(const [id,rec,status,amount,interest,notes] of [['own','esther','approved',100,10,''],['other','david','approved',200,20,''],['pending','esther','pending',300,30,''],['held','esther','rejected',0,0,''],['internal','esther','approved',50,5,'Scheduled prepayment release: held']])
 await db.query("insert into pb_repayments values($1,'biz',$2,'m','l','old','2026-10-10',now(),null,$3,$4,$5,$6)",[id,rec,status,amount,interest,notes]);
 await db.exec(`insert into pb_excess_payments values('e','biz','held','scheduled_prepayment',now(),'pending',80);
 insert into pb_savings values('s','biz','david','m','old','2026-10-10',now(),'approved',70);
 insert into pb_repayments values('outsider','other','outside','x',null,'other','2026-10-10',now(),null,'approved',9999,999,'');`);
 const call=async who=>{await db.query("select set_config('request.jwt.claim.sub',$1,false)",[who]);return (await db.query("select public.pb_officer_book_activity('2026-10-01','2026-10-15') result")).rows[0].result;};
 for(const who of ['admin','esther','boss']){
 const result=await call(who);assert.equal(result.authorized,true);assert.equal(result.rows.length,1);
 assert.deepEqual(result.rows[0],{officerId:'esther',groupId:'g',collections:380,interest:30,savings:70});
 }
 assert.equal((await call('david')).rows.length,0,'recorder cannot see another officer book');
 assert.equal((await call('outside')).rows[0].collections,9999,'business boundary respected');
 assert.equal((await call('unknown')).authorized,false);
 await db.exec("update pb_groups set officer_id='david' where id='g'");
 assert.equal((await call('esther')).rows.length,0,'transferred group access is removed');
 assert.equal((await call('david')).rows[0].collections,380,'book follows current responsibility');
 assert.equal((await db.query("select count(*) n from pb_repayments where recorded_by='david'")).rows[0].n,1,'recorder is preserved');
 await db.close();console.log('Book totals include other recorders, held receipts once, exclude internal releases, respect scope and follow transfers.');
})().catch(e=>{console.error(e);process.exitCode=1;});
