-- Wamama Pamoja Enterprise
-- Read-only speed and egress audit. This file changes no data or settings.

with table_usage as (
  select 'pb_groups' table_name, count(*) rows, coalesce(sum(pg_column_size(t)),0) row_bytes from public.pb_groups t
  union all select 'pb_members',count(*),coalesce(sum(pg_column_size(t)),0) from public.pb_members t
  union all select 'pb_guarantors',count(*),coalesce(sum(pg_column_size(t)),0) from public.pb_guarantors t
  union all select 'pb_staff',count(*),coalesce(sum(pg_column_size(t)),0) from public.pb_staff t
  union all select 'pb_inventory',count(*),coalesce(sum(pg_column_size(t)),0) from public.pb_inventory t
  union all select 'pb_loans',count(*),coalesce(sum(pg_column_size(t)),0) from public.pb_loans t
  union all select 'pb_orders',count(*),coalesce(sum(pg_column_size(t)),0) from public.pb_orders t
  union all select 'pb_savings',count(*),coalesce(sum(pg_column_size(t)),0) from public.pb_savings t
  union all select 'pb_repayments',count(*),coalesce(sum(pg_column_size(t)),0) from public.pb_repayments t
  union all select 'pb_excess_payments',count(*),coalesce(sum(pg_column_size(t)),0) from public.pb_excess_payments t
  union all select 'pb_meetings',count(*),coalesce(sum(pg_column_size(t)),0) from public.pb_meetings t
  union all select 'pb_suppliers',count(*),coalesce(sum(pg_column_size(t)),0) from public.pb_suppliers t
  union all select 'pb_purchases',count(*),coalesce(sum(pg_column_size(t)),0) from public.pb_purchases t
  union all select 'pb_purchase_lines',count(*),coalesce(sum(pg_column_size(t)),0) from public.pb_purchase_lines t
  union all select 'pb_reconciliations',count(*),coalesce(sum(pg_column_size(t)),0) from public.pb_reconciliations t
  union all select 'pb_expenses',count(*),coalesce(sum(pg_column_size(t)),0) from public.pb_expenses t
), stats as (
  select relname table_name, seq_scan, idx_scan, n_live_tup, n_dead_tup,
         last_autovacuum, last_autoanalyze
  from pg_stat_user_tables
  where schemaname='public' and relname like 'pb_%'
), updated_support as (
  select c.table_name,
         exists (
           select 1 from information_schema.columns col
           where col.table_schema='public' and col.table_name=c.table_name and col.column_name='updated_at'
         ) has_updated_at,
         exists (
           select 1 from pg_indexes i
           where i.schemaname='public' and i.tablename=c.table_name and i.indexdef ilike '%updated_at%'
         ) has_updated_at_index
  from (select table_name from table_usage) c
)
select 1 section_order, 'table_transfer_estimate' section,
       jsonb_agg(jsonb_build_object(
         'table',u.table_name,
         'rows',u.rows,
         'estimated_row_data',pg_size_pretty(u.row_bytes),
         'average_row_bytes',case when u.rows>0 then round(u.row_bytes::numeric/u.rows) else 0 end,
         'has_updated_at',x.has_updated_at,
         'has_updated_at_index',x.has_updated_at_index
       ) order by u.row_bytes desc) result
from table_usage u join updated_support x using(table_name)
union all
select 2, 'database_scan_health',
       jsonb_agg(jsonb_build_object(
         'table',s.table_name,'estimated_live_rows',s.n_live_tup,'dead_rows',s.n_dead_tup,
         'sequential_scans',s.seq_scan,'index_scans',s.idx_scan,
         'last_autovacuum',s.last_autovacuum,'last_autoanalyze',s.last_autoanalyze
       ) order by s.n_live_tup desc)
from stats s
union all
select 3, 'database_size',
       jsonb_build_object(
         'current_database',current_database(),
         'database_size',pg_size_pretty(pg_database_size(current_database())),
         'financial_data_changed',false
       )
order by section_order;
