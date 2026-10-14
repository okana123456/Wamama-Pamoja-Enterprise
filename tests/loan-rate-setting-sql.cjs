const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
(async()=>{
  const db=new PGlite();
  await db.exec(`create table public.pb_staff(business_id text);
    create table public.pb_settings(id text primary key,monthly_interest_rate numeric);
    create table public.pb_loans(id text,total_payable numeric,weekly_installment numeric);
    insert into pb_staff values('b3462eea-1c92-4411-9507-fb6c0b31ba28');
    insert into pb_settings values('biz_b3462eea-1c92-4411-9507-fb6c0b31ba28',2.5),('other',3);
    insert into pb_loans values('existing',2760.10,230.01);`);
  const sql=fs.readFileSync(path.join(__dirname,'../wamama-set-monthly-interest-2-percent.sql'),'utf8');
  await db.exec(sql);await db.exec(sql);
  const settings=(await db.query('select * from pb_settings order by id')).rows;
  assert.equal(Number(settings[0].monthly_interest_rate),2);
  assert.equal(Number(settings[1].monthly_interest_rate),3);
  const loan=(await db.query('select * from pb_loans')).rows[0];
  assert.equal(Number(loan.total_payable),2760.10);assert.equal(Number(loan.weekly_installment),230.01);
  await db.close();console.log('Wamama rate update is repeatable, tenant-scoped and preserves existing loan amounts.');
})().catch(error=>{console.error(error);process.exitCode=1;});
