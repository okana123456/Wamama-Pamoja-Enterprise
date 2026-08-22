-- Wamama Pamoja Enterprise
-- Read-only RLS/access-control performance audit.
-- This script does not change policies, functions, permissions or business data.

with policy_rows as (
  select
    tablename,
    policyname,
    cmd,
    roles,
    qual,
    with_check
  from pg_policies
  where schemaname = 'public'
    and tablename like 'pb\_%' escape '\'
),
function_rows as (
  select
    n.nspname as schema_name,
    p.proname as function_name,
    pg_get_function_identity_arguments(p.oid) as arguments,
    p.prosecdef as security_definer,
    case p.provolatile
      when 'i' then 'immutable'
      when 's' then 'stable'
      else 'volatile'
    end as volatility,
    pg_get_functiondef(p.oid) as definition
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and (
      pg_get_functiondef(p.oid) ilike '%pb_staff%'
      or pg_get_functiondef(p.oid) ilike '%auth.uid()%'
      or pg_get_functiondef(p.oid) ilike '%business_id%'
    )
),
index_rows as (
  select
    tablename,
    indexname,
    indexdef
  from pg_indexes
  where schemaname = 'public'
    and tablename in ('pb_staff','pb_permissions','pb_billing_cycles')
)
select 1 as section_order,
       'pb_table_policies' as section,
       coalesce(jsonb_agg(to_jsonb(policy_rows) order by tablename, policyname),'[]'::jsonb) as result
from policy_rows
union all
select 2,
       'access_helper_functions',
       coalesce(jsonb_agg(to_jsonb(function_rows) order by function_name, arguments),'[]'::jsonb)
from function_rows
union all
select 3,
       'access_indexes',
       coalesce(jsonb_agg(to_jsonb(index_rows) order by tablename, indexname),'[]'::jsonb)
from index_rows
order by section_order;
