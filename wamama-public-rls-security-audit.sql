-- Read-only. Run in the Wamama project SQL Editor.
-- Lists every public base table without Row-Level Security and shows whether
-- signed-out (anon) or signed-in (authenticated) API roles can reach it.
-- No tables, grants, policies, or data are changed.

select
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  (select count(*) from pg_policies p
   where p.schemaname = 'public' and p.tablename = c.relname) as policy_count,
  (
    has_table_privilege('anon', c.oid, 'SELECT')
    or has_any_column_privilege('anon', c.oid, 'SELECT')
  ) as anon_can_read,
  (
    has_table_privilege('anon', c.oid, 'INSERT')
    or has_any_column_privilege('anon', c.oid, 'INSERT')
  ) as anon_can_insert,
  (
    has_table_privilege('anon', c.oid, 'UPDATE')
    or has_any_column_privilege('anon', c.oid, 'UPDATE')
  ) as anon_can_update,
  has_table_privilege('anon', c.oid, 'DELETE') as anon_can_delete,
  (
    has_table_privilege('authenticated', c.oid, 'SELECT')
    or has_any_column_privilege('authenticated', c.oid, 'SELECT')
  ) as signed_in_can_read,
  (
    has_table_privilege('authenticated', c.oid, 'INSERT')
    or has_any_column_privilege('authenticated', c.oid, 'INSERT')
  ) as signed_in_can_insert,
  (
    has_table_privilege('authenticated', c.oid, 'UPDATE')
    or has_any_column_privilege('authenticated', c.oid, 'UPDATE')
  ) as signed_in_can_update,
  has_table_privilege('authenticated', c.oid, 'DELETE') as signed_in_can_delete
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind in ('r', 'p')
  and not c.relrowsecurity
order by
  (
    has_table_privilege('anon', c.oid, 'SELECT')
    or has_any_column_privilege('anon', c.oid, 'SELECT')
    or has_table_privilege('anon', c.oid, 'INSERT')
    or has_any_column_privilege('anon', c.oid, 'INSERT')
    or has_table_privilege('anon', c.oid, 'UPDATE')
    or has_any_column_privilege('anon', c.oid, 'UPDATE')
    or has_table_privilege('anon', c.oid, 'DELETE')
  ) desc,
  c.relname;
