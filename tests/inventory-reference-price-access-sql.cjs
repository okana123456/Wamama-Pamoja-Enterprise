const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

(async()=>{
  const db=new PGlite();
  const business='00000000-0000-0000-0000-000000000001';
  const manager='00000000-0000-0000-0000-000000000002';
  const buyer='00000000-0000-0000-0000-000000000003';
  const asset='00000000-0000-0000-0000-000000000004';
  await db.exec(`
    create role anon;
    create role authenticated;
    create schema auth;
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
    $$;
    create function auth.role() returns text language sql stable as $$
      select nullif(current_setting('request.jwt.claim.role',true),'')
    $$;
    grant usage on schema public, auth to authenticated, anon;
    grant execute on function auth.uid(), auth.role() to authenticated, anon;
    create table public.pb_staff(
      id uuid primary key, business_id uuid, auth_user_id uuid,
      status text, role text, full_name text
    );
    create table public.pb_inventory(
      id uuid primary key, business_id uuid, name text, category text,
      stock numeric, buying_price numeric not null, purchase_price numeric,
      loan_price numeric, reorder_level numeric, cost_method text,
      cost_adjustment numeric
    );
    alter table public.pb_inventory enable row level security;
    create policy "Tenant Isolation" on public.pb_inventory
      to authenticated using (true) with check (true);
    alter table public.pb_staff enable row level security;
    create policy "Tenant Isolation" on public.pb_staff
      to authenticated using (true) with check (true);
    grant all on public.pb_staff, public.pb_inventory to authenticated;
    insert into public.pb_staff values
      ('00000000-0000-0000-0000-000000000012','${business}','${manager}','active','admin','Manager'),
      ('00000000-0000-0000-0000-000000000013','${business}','${buyer}','active','inventory_officer','Buyer');
    insert into public.pb_inventory values
      ('${asset}','${business}','Bag','Other',8,1600,1500,1650,5,'weighted_average',0),
      ('00000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000099','Other business item','Other',2,900,800,1000,5,'manual',0);
  `);
  const migration=fs.readFileSync(path.join(__dirname,'../wamama-inventory-reference-price-access.sql'),'utf8');
  await db.exec(migration);
  await db.exec(migration);
  await db.exec(fs.readFileSync(path.join(__dirname,'../wamama-inventory-reference-price-access-check.sql'),'utf8'));
  const rights=(await db.query(`select
    has_column_privilege('authenticated','public.pb_inventory','stock','SELECT') as stock_read,
    has_column_privilege('authenticated','public.pb_inventory','stock','UPDATE') as stock_write,
    has_column_privilege('authenticated','public.pb_inventory','purchase_price','SELECT') as wholesale_read,
    has_column_privilege('authenticated','public.pb_inventory','purchase_price','UPDATE') as wholesale_write,
    has_column_privilege('authenticated','public.pb_inventory','buying_price','SELECT') as valuation_read
  `)).rows[0];
  assert.equal(rights.stock_read,true);
  assert.equal(rights.stock_write,true);
  assert.equal(rights.wholesale_read,false);
  assert.equal(rights.wholesale_write,false);
  assert.equal(rights.valuation_read,false);
  const runAs=async(user,sql)=>{
    await db.exec(`set request.jwt.claim.sub='${user}'; set request.jwt.claim.role='authenticated'; set role authenticated`);
    try{return await db.query(sql);} finally {await db.exec('reset role');}
  };
  const rejectAs=async(user,sql)=>{
    let rejected=false;
    try{await runAs(user,sql);}catch{rejected=true;}
    assert.equal(rejected,true,`Expected restricted SQL to fail: ${sql}`);
  };
  await rejectAs(buyer,`select purchase_price from public.pb_inventory where id='${asset}'`);
  await rejectAs(buyer,`select * from public.pb_inventory where id='${asset}'`);
  const safe=await runAs(buyer,`select stock,loan_price from public.pb_inventory where id='${asset}'`);
  assert.equal(Number(safe.rows[0].stock),8);
  await runAs(buyer,`update public.pb_inventory set stock=stock+1 where id='${asset}'`);
  await rejectAs(buyer,`select * from public.pb_inventory_reference_prices()`);
  await rejectAs(buyer,`select * from public.pb_set_inventory_reference_prices('${asset}',1400,1500)`);
  await rejectAs(buyer,`update public.pb_staff set role='admin' where auth_user_id='${buyer}'`);
  await rejectAs(buyer,`update public.pb_inventory set loan_price=900 where id='${asset}'`);
  const managerPrices=await runAs(manager,`select * from public.pb_inventory_reference_prices()`);
  assert.equal(managerPrices.rows.length,1,'manager RPC is scoped to their business');
  assert.equal(Number(managerPrices.rows[0].purchase_price),1500);
  await runAs(manager,`select * from public.pb_set_inventory_reference_prices('${asset}',1550,1575)`);
  const final=(await db.query(`select stock,purchase_price,buying_price,loan_price from public.pb_inventory where id='${asset}'`)).rows[0];
  assert.equal(Number(final.stock),9);
  assert.equal(Number(final.purchase_price),1550);
  assert.equal(Number(final.buying_price),1575);
  assert.equal(Number(final.loan_price),1650);
  await db.close();
  console.log('Inventory price privileges, officer denial, management RPCs, and staff role guard passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
