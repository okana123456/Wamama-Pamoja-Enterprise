const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
(async()=>{
 const db=new PGlite(),id=n=>'00000000-0000-0000-0000-'+String(n).padStart(12,'0');
 const biz='b3462eea-1c92-4411-9507-fb6c0b31ba28';
 const previousTest=fs.readFileSync(path.join(__dirname,'due-prepayment-release-sql.cjs'),'utf8');
 await db.exec(previousTest.match(/await db.exec\(`([\s\S]*?)`\);/)[1]);
 await db.exec(fs.readFileSync(path.join(__dirname,'../wamama-optimize-prepayment-release.sql'),'utf8'));
 await db.exec(`create schema auth;create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create table pb_staff(id uuid,business_id text,auth_user_id uuid,status text);
 create table pb_members(id uuid,business_id text,group_id text,full_name text);
 create table pb_groups(id uuid,business_id text,name text);
 create table pb_savings(amount numeric);insert into pb_savings values(700);
 alter table pb_loans add column asset_name text;
 alter table pb_excess_payments add column original_payment_amount numeric;
 create schema cron;create table cron.job(jobid bigint generated always as identity,jobname text unique,schedule text,command text,active bool default true);
 create function cron.schedule(text,text,text) returns bigint language plpgsql as $$declare v bigint;begin
 insert into cron.job(jobname,schedule,command) values($1,$2,$3) on conflict(jobname) do update set schedule=$2,command=$3 returning jobid into v;return v;end$$;
 insert into pb_staff values('${id(1)}','${biz}','${id(1)}','active');
 insert into pb_members values('${id(101)}','${biz}','${id(201)}','PERES AKONG''O WAGOYA');
 insert into pb_groups values('${id(201)}','${biz}','Mumbo women group');
 insert into pb_loans(id,business_id,member_id,group_id,status,total_payable,loan_value,weekly_installment,start_date,expected_end_date,asset_name) values
 ('${id(10)}','${biz}','${id(101)}','${id(201)}','active',925.4,800,185.08,'2026-09-25','2026-10-30','Kikoi'),
 ('${id(11)}','${biz}','${id(101)}','${id(201)}','active',1728,1500,432,'2026-10-23','2026-11-13','Plates');
 insert into pb_repayments(id,business_id,loan_id,member_id,group_id,meeting_date,amount,principal,interest,status) values
 ('${id(30)}','${biz}','${id(10)}','${id(101)}','${id(201)}','2026-10-23',910,800,110,'approved'),
 ('${id(31)}','${biz}','${id(11)}','${id(101)}','${id(201)}','2026-10-23',432,375,57,'approved'),
 ('${id(32)}','${biz}','${id(11)}','${id(101)}','${id(201)}','2026-10-23',1171.6,0,0,'rejected');
 insert into pb_excess_payments(id,business_id,member_id,group_id,loan_id,original_repayment_id,payment_date,excess_amount,original_payment_amount,status,source) values
 ('${id(40)}','${biz}','${id(101)}','${id(201)}','${id(11)}','${id(32)}','2026-10-23',1171.6,1171.6,'pending','scheduled_prepayment');`);
 const original=(await db.query("select * from pb_repayments where notes is null order by id")).rows;
 const sql=fs.readFileSync(path.join(__dirname,'../wamama-shared-deposit-auto-allocation.sql'),'utf8')
 .replace('create extension if not exists pg_cron with schema pg_catalog;','-- Cron is simulated in the embedded test.')
 .replaceAll("(now() at time zone 'Africa/Nairobi')::date","date '2026-10-28'");
 await db.exec(sql);
 const balance=async()=>Number((await db.query(`select excess_amount-released_amount amount from pb_excess_payments where id='${id(40)}'`)).rows[0].amount);
 assert.equal(await balance(),1156.2,'15.40 from shared deposits covers the oldest due loan');
 assert.equal((await db.query(`select status from pb_loans where id='${id(10)}'`)).rows[0].status,'completed');
 assert.deepEqual((await db.query("select * from pb_repayments where notes is null order by id")).rows,original,'original cash records preserved');
 await db.exec(sql);assert.equal(await balance(),1156.2,'repeat setup does not spend twice');
 assert.equal((await db.query('select count(*) n from cron.job')).rows[0].n,1,'one recurring job');
 await db.exec(`update pb_loans set status='active',total_payable=940,weekly_installment=190 where id='${id(10)}';`);
 await db.query('select wamama_deposit_private.release_due($1,null,100)',[biz]);
 assert.equal(await balance(),1141.6,'a later same-due-date adjustment can be covered');
 const allocations=(await db.query(`select allocation_offset,amount from pb_prepayment_releases where loan_id='${id(10)}' order by allocation_offset`)).rows;
 assert.equal(allocations.length,2);assert.equal(Number(allocations[1].allocation_offset),15.4);
 assert.equal((await db.query('select amount from pb_savings')).rows[0].amount,'700');
 await db.exec(`insert into pb_members values('${id(102)}','${biz}','${id(201)}','Another client');
 insert into pb_loans(id,business_id,member_id,group_id,status,total_payable,loan_value,weekly_installment,start_date) values
 ('${id(12)}','${biz}','${id(102)}','${id(201)}','active',100,80,100,'2026-10-28');
 insert into pb_repayments(id,business_id,loan_id,member_id,group_id,meeting_date,amount,status) values
 ('${id(33)}','${biz}','${id(12)}','${id(102)}','${id(201)}','2026-10-28',100,'rejected');
 insert into pb_excess_payments(id,business_id,member_id,loan_id,original_repayment_id,payment_date,excess_amount,original_payment_amount,status,source) values
 ('${id(41)}','${biz}','${id(102)}','${id(12)}','${id(33)}','2026-10-28',100,100,'pending','scheduled_prepayment');`);
 await db.query('select wamama_deposit_private.release_due($1,null,100)',[biz]);
 assert.equal((await db.query(`select status from pb_loans where id='${id(12)}'`)).rows[0].status,'completed','same-day cash is eligible');
 await db.exec(`insert into pb_members values('${id(103)}','${biz}','${id(201)}','Protected deposits');
 insert into pb_loans(id,business_id,member_id,group_id,status,total_payable,loan_value,weekly_installment,start_date) values
 ('${id(13)}','${biz}','${id(103)}','${id(201)}','active',100,80,100,'2026-10-28');`);
 for(const [n,source,status,date,voided] of [[42,'pre_loan_deposit','approved','2026-10-28',null],
 [43,'scheduled_prepayment','pending','2026-10-28',null],
 [44,'scheduled_prepayment','rejected','2026-10-29',null],
 [45,'scheduled_prepayment','rejected','2026-10-28','2026-10-28T00:00:00Z']]){
 await db.query('insert into pb_repayments(id,business_id,loan_id,member_id,group_id,meeting_date,amount,status,voided_at) values($1,$2,$3,$4,$5,$6,0,$7,$8)',[id(n+100),biz,id(13),id(103),id(201),date,status,voided]);
 await db.query("insert into pb_excess_payments(id,business_id,member_id,loan_id,original_repayment_id,payment_date,excess_amount,original_payment_amount,status,source) values($1,$2,$3,$4,$5,$6,100,100,'pending',$7)",[id(n),biz,id(103),id(13),id(n+100),date,source]);
 }
 await db.query('select wamama_deposit_private.release_due($1,null,100)',[biz]);
 assert.equal(Number((await db.query(`select sum(released_amount) amount from pb_excess_payments where member_id='${id(103)}'`)).rows[0].amount),0,'earmarked, unapproved, future and voided cash are not spent');
 assert.equal(await balance(),1141.6,'one client cannot spend another client deposit');
 await db.exec(`insert into pb_members values('${id(104)}','${biz}','${id(201)}','Early-close remainder');
 insert into pb_loans(id,business_id,member_id,group_id,status,total_payable,loan_value,weekly_installment,start_date) values
 ('${id(14)}','${biz}','${id(104)}','${id(201)}','active',100,80,100,'2026-10-28');
 insert into pb_repayments(id,business_id,loan_id,member_id,group_id,meeting_date,amount,status) values
 ('${id(150)}','${biz}','${id(14)}','${id(104)}','${id(201)}','2026-10-20',200,'rejected');
 insert into pb_excess_payments(id,business_id,member_id,loan_id,original_repayment_id,payment_date,excess_amount,released_amount,original_payment_amount,status,source) values
 ('${id(50)}','${biz}','${id(104)}','${id(14)}','${id(150)}','2026-10-20',200,100,200,'pending','scheduled_prepayment');`);
 await db.query('select wamama_deposit_private.release_due($1,null,100)',[biz]);
 assert.equal((await db.query(`select status from pb_loans where id='${id(14)}'`)).rows[0].status,'completed','an early-close allocation outside the scheduled ledger does not strand the remainder');
 await db.exec('set role anon');
 await assert.rejects(db.query('select public.pb_release_due_prepayments(null,25)'),/permission denied/);
 await db.exec('reset role');await db.exec('set role authenticated');
 await assert.rejects(db.query('select wamama_deposit_private.release_due($1,null,25)',[biz]),/permission denied/);
 await assert.rejects(db.query('select public.pb_release_due_prepayments(null,25)'),/active Wamama staff session/);
 await db.exec('reset role');await db.close();
 console.log('Shared deposits cover due debt across active loans; same-day cash/top-ups work; cash and savings preserved; repeat runs safe; private worker and anonymous RPC locked down.');
})().catch(e=>{console.error(e.message);process.exitCode=1;});
