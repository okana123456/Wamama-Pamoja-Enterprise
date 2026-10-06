const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
(async()=>{
 const db=new PGlite();
 await db.exec(`create table pb_inventory(
   id uuid primary key,stock numeric,buying_price numeric,loan_price numeric,purchase_price numeric);
  create table pb_purchases(id uuid primary key,received_on date);
  create table pb_purchase_lines(id uuid primary key,purchase_id uuid,asset_id uuid,cost_per_unit numeric);
  insert into pb_inventory values
  ('00000000-0000-0000-0000-000000000001',8,1600,1650,null);
  insert into pb_purchases values('00000000-0000-0000-0000-000000000011','2026-10-05');
  insert into pb_purchase_lines values('00000000-0000-0000-0000-000000000021','00000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000001',1500);`);
 const sql=fs.readFileSync(path.join(__dirname,'../wamama-inventory-receipt-price-guard.sql'),'utf8');
 await db.exec(sql);await db.exec(sql);
 // Old clients used to write all three changes after receiving 12 units at 1500.
 await db.exec(`update pb_inventory set stock=20,buying_price=1540,loan_price=1588.13
  where id='00000000-0000-0000-0000-000000000001';`);
 let row=(await db.query('select stock,buying_price,loan_price,purchase_price from pb_inventory')).rows[0];
 assert.equal(Number(row.stock),20);
 assert.equal(Number(row.buying_price),1540);
 assert.equal(Number(row.loan_price),1650,'legacy receipt cannot lower the approved selling price');
 assert.equal(Number(row.purchase_price),1500,'linked actual supplier price is backfilled without repricing');
 await db.exec(`update pb_inventory set loan_price=1600
  where id='00000000-0000-0000-0000-000000000001';`);
 row=(await db.query('select loan_price from pb_inventory')).rows[0];
 assert.equal(Number(row.loan_price),1600,'a manager can change the selling price separately');
 await db.close();
 console.log('Legacy receipt price guard preserves selling price and permits separate management edits.');
})().catch(error=>{console.error(error);process.exitCode=1;});
