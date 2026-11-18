-- Wamama Pamoja Enterprise: READ-ONLY production check.
-- Changes nothing. Run in the Supabase SQL editor and send back the single
-- JSON result (it contains no client names, amounts or identifiers).
-- Run once BEFORE the idempotency migration and once AFTER it.
with
fn as (
  select p.proname,
         md5(pg_get_functiondef(p.oid)) as definition_md5,
         p.prosecdef as security_definer,
         pg_get_functiondef(p.oid) ilike '%client_operation_id%' as uses_operation_id,
         pg_get_functiondef(p.oid) ilike '%interval ''30 seconds''%' as has_30_second_window,
         has_function_privilege('anon', p.oid, 'execute') as anon_can_execute,
         has_function_privilege('authenticated', p.oid, 'execute') as authenticated_can_execute
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in (
    'pb_record_repayments_batch','pb_submit_meeting','pb_record_repayment_operation','pb_record_saving_operation',
    'pb_block_rapid_duplicate_pending_repayment','pb_guard_repeated_meeting_receipt','pb_guard_repeated_meeting_saving',
    'pb_capture_repayment_excess','pb_release_due_prepayments','pb_approve_savings','pb_financial_snapshot',
    'pb_officer_book_activity','pb_financial_snapshot_v2')
),
trg as (
  -- Postgres fires BEFORE triggers on one table in name order.
  select c.relname as table_name, t.tgname as trigger_name,
         case when t.tgtype & 2 = 2 then 'before' else 'after' end as timing,
         p.proname as function_name, t.tgenabled as enabled
  from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_proc p on p.oid = t.tgfoid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and not t.tgisinternal
    and c.relname in ('pb_repayments','pb_savings','pb_meetings','pb_excess_payments','pb_prepayment_releases')
),
sync_ready as (
  -- Changed-rows sync needs updated_at kept current on every synced table.
  select tbl as table_name,
         exists(select 1 from information_schema.columns col where col.table_schema='public'
           and col.table_name=tbl and col.column_name='updated_at') as has_updated_at,
         exists(select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
           where n.nspname='public' and c.relname=tbl and t.tgname='pb_touch_updated_at_trigger' and t.tgenabled<>'D') as touch_trigger_enabled
  from unnest(array['pb_groups','pb_members','pb_guarantors','pb_staff','pb_inventory','pb_loans','pb_orders',
    'pb_savings','pb_repayments','pb_excess_payments','pb_meetings','pb_suppliers','pb_purchases',
    'pb_purchase_lines','pb_reconciliations','pb_expenses']) tbl
  where to_regclass('public.'||tbl) is not null
),
idx as (
  select tablename, indexname, indexdef ilike '%unique%' as is_unique, indexdef
  from pg_indexes where schemaname = 'public'
    and tablename in ('pb_repayments','pb_savings','pb_meetings','pb_excess_payments','pb_prepayment_releases','pb_loans','pb_members')
),
cols as (
  select table_name, column_name, data_type from information_schema.columns
  where table_schema = 'public' and column_name in ('client_operation_id','client_operation_hash','updated_at','business_id','id')
    and table_name in ('pb_repayments','pb_savings','pb_meetings','pb_excess_payments','pb_loans','pb_members')
),
sizes as (
  select c.relname as table_name, c.reltuples::bigint as approx_rows,
         pg_total_relation_size(c.oid) as total_bytes
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'pb\_%'
),
per_business as (
  -- Largest business histories, without identifying the business.
  select 'pb_savings' t, max(n) max_rows from (select count(*) n from public.pb_savings group by business_id) x
  union all select 'pb_repayments', max(n) from (select count(*) n from public.pb_repayments group by business_id) x
  union all select 'pb_loans', max(n) from (select count(*) n from public.pb_loans group by business_id) x
  union all select 'pb_members', max(n) from (select count(*) n from public.pb_members group by business_id) x
  union all select 'pb_excess_payments', max(n) from (select count(*) n from public.pb_excess_payments group by business_id) x
),
dup_ops as (
  select 'excess_per_repayment' as check_name, count(*) as violations from (
    select original_repayment_id from public.pb_excess_payments
    where original_repayment_id is not null group by original_repayment_id having count(*) > 1) x
),
pol as (
  select tablename, policyname, cmd, roles::text,
         (coalesce(qual,'') || coalesce(with_check,'')) ~* 'auth\.uid\(\)' and
         (coalesce(qual,'') || coalesce(with_check,'')) !~* '\(\s*select\s+auth\.uid\(\)' as calls_auth_uid_per_row
  from pg_policies where schemaname = 'public'
    and tablename in ('pb_repayments','pb_savings','pb_loans','pb_members','pb_groups','pb_excess_payments','pb_meetings')
),
settings as (
  select r.rolname, coalesce(array_to_string(r.rolconfig, ','), '') as role_settings
  from pg_roles r where r.rolname in ('authenticated','anon','authenticator')
)
select jsonb_pretty(jsonb_build_object(
  'checked_at', now(),
  'server_version', current_setting('server_version'),
  'functions', (select coalesce(jsonb_agg(to_jsonb(fn) order by proname), '[]') from fn),
  'triggers', (select coalesce(jsonb_agg(to_jsonb(trg) order by table_name, timing, trigger_name), '[]') from trg),
  'sync_tables_not_ready', (select coalesce(jsonb_agg(to_jsonb(s) order by table_name), '[]') from sync_ready s
    where not (s.has_updated_at and s.touch_trigger_enabled)),
  'indexes', (select coalesce(jsonb_agg(to_jsonb(idx) order by tablename, indexname), '[]') from idx),
  'columns', (select coalesce(jsonb_agg(to_jsonb(cols) order by table_name, column_name), '[]') from cols),
  'table_sizes', (select coalesce(jsonb_agg(to_jsonb(sizes) order by total_bytes desc), '[]') from sizes),
  'largest_business_history', (select jsonb_object_agg(t, max_rows) from per_business),
  'constraint_violations', (select jsonb_agg(to_jsonb(dup_ops)) from dup_ops),
  'rls_policies', (select coalesce(jsonb_agg(to_jsonb(pol) order by tablename, policyname), '[]') from pol),
  'role_settings', (select jsonb_agg(to_jsonb(settings)) from settings),
  'pg_stat_statements_installed', exists(select 1 from pg_extension where extname = 'pg_stat_statements')
)) as wamama_production_check;
