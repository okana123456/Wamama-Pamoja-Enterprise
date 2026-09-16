-- Read-only developer check. Runs in Supabase SQL Editor; changes no data.
-- Both rows must show ready = true for reliable low-egress financial syncing.
with targets(table_name) as (
  values ('pb_savings'::text), ('pb_repayments'::text)
), checks as (
  select t.table_name,
    exists (
      select 1 from information_schema.columns c
      where c.table_schema = 'public' and c.table_name = t.table_name
        and c.column_name = 'updated_at' and c.is_nullable = 'NO'
    ) as updated_at_ready,
    exists (
      select 1 from pg_trigger tr
      where tr.tgrelid = to_regclass('public.' || t.table_name)
        and tr.tgname = 'pb_touch_updated_at_trigger'
        and tr.tgenabled <> 'D'
    ) as update_trigger_ready,
    exists (
      select 1 from pg_indexes i
      where i.schemaname = 'public' and i.tablename = t.table_name
        and i.indexname = t.table_name || '_business_updated_idx'
    ) as incremental_index_ready
  from targets t
)
select table_name, updated_at_ready, update_trigger_ready, incremental_index_ready,
       (updated_at_ready and update_trigger_ready and incremental_index_ready) as ready
from checks
order by table_name;
