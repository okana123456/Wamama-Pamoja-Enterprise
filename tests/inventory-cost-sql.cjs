const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
(async()=>{
 const db=new PGlite();
 await db.exec(`create table pb_inventory(id uuid primary key,business_id uuid,stock numeric,buying_price numeric,loan_price numeric);
  create table pb_purchases(id uuid primary key,received_on date);
  create table pb_purchase_lines(id uuid primary key,purchase_id uuid,asset_id uuid,cost_per_unit numeric);
  insert into pb_inventory values
   ('00000000-0000-0000-0000-000000000001',null,10,10000,14000),
   ('00000000-0000-0000-0000-000000000002',null,5,2000,3000);
  insert into pb_purchases values
   ('00000000-0000-0000-0000-000000000011','2026-09-01'),
   ('00000000-0000-0000-0000-000000000012','2026-09-29');
  insert into pb_purchase_lines values
   ('00000000-0000-0000-0000-000000000021','00000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000001',9800),
   ('00000000-0000-0000-0000-000000000022','00000000-0000-0000-0000-000000000012','00000000-0000-0000-0000-000000000001',10500);`);
 const sql=fs.readFileSync(path.join(__dirname,'../wamama-inventory-cost-separation.sql'),'utf8');
 await db.exec(sql);await db.exec(sql);
 const {rows}=await db.query('select id,stock,buying_price,purchase_price,cost_method,cost_adjustment,loan_price from pb_inventory order by id');
 assert.equal(Number(rows[0].purchase_price),10500,'latest actual linked purchase is recovered');
 assert.equal(Number(rows[0].buying_price),10000,'historical valuation cost is not rewritten');
 assert.equal(Number(rows[0].loan_price),14000,'approved selling price is not changed');
 assert.equal(rows[0].cost_method,'weighted_average');
 assert.equal(rows[1].purchase_price,null,'unknown supplier price is not invented from cost');
 assert.equal(Number(rows[1].loan_price),3000);
 const check=(await db.query(`select count(*) as n from pg_constraint where conname='pb_inventory_cost_method_check'`)).rows[0];
 assert.equal(Number(check.n),1,'the setup is idempotent');
 await db.close();
 console.log('Inventory migration: linked purchase backfill, unknown-price preservation and unchanged loan prices passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
