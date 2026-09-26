const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const db=new PGlite(),id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
 const biz=id(1),admin=id(2),officer=id(3),other=id(4),branch=id(5),inactive=id(6);
 await db.exec(`create role anon;create role authenticated;create schema auth;
  create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
  grant usage on schema public,auth to authenticated;
  create table pb_staff(id uuid primary key,auth_user_id uuid,business_id uuid,role text,status text,full_name text);
  create table pb_loans(id uuid primary key,business_id uuid,member_id uuid,status text,deposit_applied numeric default 0,updated_at timestamptz default now());
  create table pb_repayments(id uuid primary key,loan_id uuid references pb_loans(id),status text,amount numeric,principal numeric,interest numeric,voided_at timestamptz);
  create table pb_excess_payments(id uuid primary key,loan_id text,original_repayment_id text);
  create table pb_prepayment_releases(id uuid primary key,loan_id text);
  create table pb_preloan_deposit_applications(id uuid primary key,loan_id text);
  create table pb_audit_log(business_id uuid,staff_id uuid,staff_name text,action text,entity text,entity_id text,old_value jsonb,new_value jsonb);
  insert into pb_staff values('${admin}','${admin}','${biz}','admin','active','Administrator'),
   ('${officer}','${officer}','${biz}','loan_officer','active','Officer'),
   ('${other}','${other}','${id(10)}','admin','active','Other tenant'),
   ('${branch}','${branch}','${biz}','branch_manager','active','Manager'),
   ('${inactive}','${inactive}','${biz}','admin','inactive','Inactive');`);
 const setup=fs.readFileSync(path.join(__dirname,'../wamama-cancel-unused-loan.sql'),'utf8');
 await db.exec(setup);await db.exec(setup);
 const insert=async(table,row)=>{const keys=Object.keys(row);await db.query(`insert into ${table}(${keys.join(',')}) values(${keys.map((_,i)=>'$'+(i+1)).join(',')})`,Object.values(row));};
 const loan=async(n,extra={})=>{const loanId=id(n);await insert('pb_loans',{id:loanId,business_id:biz,member_id:id(11),status:'active',...extra});return loanId;};
 const pay=async(n,loanId,extra={})=>insert('pb_repayments',{id:id(n),loan_id:loanId,status:'approved',amount:0,principal:0,interest:0,...extra});
 const cancel=async(actor,loanId,reason='Created in error')=>{
  await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[actor]);
  await db.exec('set role authenticated');
  try{return (await db.query('select public.pb_cancel_unused_loan($1,$2) as result',[loanId,reason])).rows[0].result;}
  finally{await db.exec('reset role');}
 };
 const status=async loanId=>(await db.query('select status from pb_loans where id=$1',[loanId])).rows[0].status;
 const original=await loan(20),kept=await loan(21);
 await pay(30,original,{voided_at:'2026-09-26',amount:800});
 await pay(31,original,{voided_at:'2026-09-26',amount:0});
 const before=(await db.query('select * from pb_repayments where loan_id=$1 order by id',[original])).rows;
 const result=await cancel(admin,original);
 assert.equal(result.status,'cancelled');assert.equal(result.retained_repayment_rows,2);
 assert.equal(await status(kept),'active');
 assert.deepEqual((await db.query('select * from pb_repayments where loan_id=$1 order by id',[original])).rows,before);
 let audit=(await db.query('select * from pb_audit_log')).rows;
 assert.equal(audit.length,1);assert.equal(audit[0].staff_id,admin,'native UUID actor is retained');
 assert.equal(audit[0].new_value.retained_repayment_rows,2);
 assert.equal((await cancel(admin,original)).already_cancelled,true);
 assert.equal((await db.query('select count(*)::integer as n from pb_audit_log')).rows[0].n,1);
 for(const [n,extra] of [[40,{amount:100}],[41,{status:'pending',amount:100}],
  [42,{amount:0,principal:100}],[43,{amount:0,interest:10}],[44,{amount:-10}]]){
  const active=await loan(n);await pay(n+100,active,extra);
  await assert.rejects(cancel(admin,active),/active or pending payment/);assert.equal(await status(active),'active');
 }
 const funded=await loan(50,{deposit_applied:100});
 await assert.rejects(cancel(admin,funded),/deposit was used/);
 for(const [n,table] of [[51,'pb_excess_payments'],[52,'pb_prepayment_releases'],[53,'pb_preloan_deposit_applications']]){
  const active=await loan(n);await insert(table,{id:id(n+100),loan_id:active});
  await assert.rejects(cancel(admin,active),/linked deposit records/);assert.equal(await status(active),'active');
 }
 const indirect=await loan(54);await pay(154,indirect,{voided_at:'2026-09-26'});
 await insert('pb_excess_payments',{id:id(254),loan_id:kept,original_repayment_id:id(154)});
 await assert.rejects(cancel(admin,indirect),/linked deposit records/);
 const unused=await loan(60);
 await assert.rejects(cancel(officer,unused),/Only an administrator/);
 await assert.rejects(cancel(other,unused),/not found in your business/);
 await assert.rejects(cancel(inactive,unused),/sign in again/);
 await assert.rejects(cancel('',unused),/sign in again/);
 await assert.rejects(cancel(admin,unused,'x'),/short reason/);
 assert.equal(await status(unused),'active');
 assert.equal((await cancel(branch,unused)).success,true);
 const rejected=await loan(61);await pay(161,rejected,{status:'rejected',amount:100});
 assert.equal((await cancel(admin,rejected)).success,true,'rejected audit history can be retained');
 const completed=await loan(62,{status:'completed'});
 await assert.rejects(cancel(admin,completed),/Only an active or pending/);
 // The cancellation must roll back if the audit cannot be stored.
 const rollback=await loan(63);
 await db.exec(`create function reject_audit() returns trigger language plpgsql as $$begin raise exception 'Audit unavailable';end$$;
  create trigger reject_audit before insert on pb_audit_log for each row execute function reject_audit();`);
 await assert.rejects(cancel(admin,rollback),/Audit unavailable/);
 assert.equal(await status(rollback),'active');
 await db.exec('drop trigger reject_audit on pb_audit_log');
 // Legacy installations may not have optional deposit tables.
 await db.exec('drop table pb_preloan_deposit_applications;drop table pb_prepayment_releases;drop table pb_excess_payments');
 assert.equal((await cancel(admin,await loan(64))).success,true);
 await db.exec('set role anon');
 await assert.rejects(db.query('select public.pb_cancel_unused_loan($1,$2)',[kept,'Created in error']),/permission denied/);
 await db.exec('reset role');await db.close();
 console.log('Unused loan cancellation: void history, payment/deposit safeguards, tenant/role checks and rollback passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
