const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
(async()=>{
 const db=new PGlite();
 await db.exec(`create table pb_inventory(id uuid primary key,name text,stock numeric,buying_price numeric,loan_price numeric,purchase_price numeric,cost_method text,cost_adjustment numeric,created_at timestamptz,updated_at timestamptz);
 create table pb_purchases(id uuid primary key,received_on date,supplier_name text);
 create table pb_purchase_lines(id uuid primary key,purchase_id uuid,asset_id uuid,asset_name text,quantity numeric,cost_per_unit numeric,landed_adjustment numeric,subtotal numeric);
 create table pb_orders(id uuid primary key,asset_id uuid,ordered_on date,status text,asset_name text,quantity numeric,notes text);
 insert into pb_inventory(id,name,stock,buying_price,loan_price,cost_method,cost_adjustment) values
 ('00000000-0000-0000-0000-000000000001','LAPTOP BAG MEDIUM',20,1540,1588.13,'weighted_average',0);
 insert into pb_purchases values('00000000-0000-0000-0000-000000000011','2026-10-05','Violet Traders');
 insert into pb_purchase_lines values('00000000-0000-0000-0000-000000000021','00000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000001','LAPTOP BAG MEDIUM',12,1500,0,18000);`);
 const sql=fs.readFileSync(path.join(__dirname,'../wamama-laptop-bag-price-audit.sql'),'utf8');
 const results=await db.exec(sql);
 assert.equal(results[0].rows.length,2,'asset and supplier purchase are both visible');
 assert.equal(Number(results[1].rows[0].inferred_cost_before_receipt),1600);
 assert.equal(Number(results[1].rows[0].inferred_loan_price_before_receipt),1650.01);
 const one=fs.readFileSync(path.join(__dirname,'../wamama-laptop-bag-one-result.sql'),'utf8')
  .replace('b87d8c14-e6cc-43fe-bd96-629b0321a477','00000000-0000-0000-0000-000000000001');
 const single=(await db.exec(one))[0].rows;
 assert.equal(single.length,1,'one-result audit is easy to copy');
 assert.equal(Number(single[0].supplier_price_unit),1500);
 assert.equal(Number(single[0].safeguard_installed),0);
 await db.close();
 console.log('Laptop bag incident audit returns linked purchase and non-mutating price inference.');
})().catch(error=>{console.error(error);process.exitCode=1;});
