// Server time to page through a 45,000-row business history, 1,000 rows per
// request: OFFSET paging (previous code) versus keyset paging (new code).
// PGlite runs real PostgreSQL in-process; absolute times differ from Supabase
// but the growth pattern is the same.
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const {performance}=require('node:perf_hooks');
(async()=>{
  const db=new PGlite();
  await db.exec(`create table pb_savings(id uuid primary key,business_id uuid,member_id uuid,amount numeric,status text,notes text,created_at timestamptz default now());
    create index on pb_savings(business_id);
    insert into pb_savings select gen_random_uuid(),'00000000-0000-0000-0000-000000000001',gen_random_uuid(),100,'approved',null,now() from generate_series(1,45000);
    insert into pb_savings select gen_random_uuid(),'00000000-0000-0000-0000-000000000002',gen_random_uuid(),100,'approved',null,now() from generate_series(1,20000);
    analyze pb_savings;`);
  const biz='00000000-0000-0000-0000-000000000001';
  const timeIt=async fn=>{const s=performance.now();const pages=await fn();return {ms:Math.round(performance.now()-s),pages};};
  const offset=await timeIt(async()=>{let p=0;for(let from=0;;from+=1000){const r=await db.query(`select * from pb_savings where business_id=$1 order by id limit 1000 offset ${from}`,[biz]);p++;if(r.rows.length<1000)return p;}});
  const keyset=await timeIt(async()=>{let p=0,last=null;for(;;){const r=last?await db.query(`select * from pb_savings where business_id=$1 and id>$2 order by id limit 1000`,[biz,last]):await db.query(`select * from pb_savings where business_id=$1 order by id limit 1000`,[biz]);p++;if(r.rows.length<1000)return p;last=r.rows.at(-1).id;}});
  const lastPage=async sql=>{const s=performance.now();await db.query(sql,[biz]);return +(performance.now()-s).toFixed(1);};
  const lastOffsetMs=await lastPage(`select * from pb_savings where business_id=$1 order by id limit 1000 offset 44000`);
  console.log(JSON.stringify({rows:45000,offsetTotalMs:offset.ms,keysetTotalMs:keyset.ms,pages:offset.pages,lastOffsetPageMs:lastOffsetMs}));
  await db.close();
})();
