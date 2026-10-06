-- Run after wamama-inventory-reference-price-access.sql in the SQL Editor.
-- Read-only check: raises an error if the inventory price boundary is absent.

do $$
declare
  v_column text;
  v_privilege text;
begin
  foreach v_column in array array['purchase_price', 'buying_price'] loop
    foreach v_privilege in array array['SELECT', 'INSERT', 'UPDATE'] loop
      if has_column_privilege('authenticated', 'public.pb_inventory', v_column, v_privilege)
         or has_column_privilege('anon', 'public.pb_inventory', v_column, v_privilege) then
        raise exception '% on pb_inventory.% remains available to an API role',
          v_privilege, v_column;
      end if;
    end loop;
  end loop;

  if not has_column_privilege('authenticated', 'public.pb_inventory', 'id', 'SELECT')
     or not has_column_privilege('authenticated', 'public.pb_inventory', 'stock', 'UPDATE')
     or not has_column_privilege('authenticated', 'public.pb_inventory', 'name', 'INSERT') then
    raise exception 'Normal authenticated inventory access is missing';
  end if;

  if exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'pb_inventory'
  ) then
    raise exception 'pb_inventory is still in the full-row Realtime publication';
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.pb_inventory'::regclass
      and tgname = 'pb_guard_inventory_reference_prices'
      and not tgisinternal
      and tgenabled <> 'D'
  ) then
    raise exception 'Inventory reference-price guard trigger is absent';
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.pb_staff'::regclass
      and tgname = 'pb_guard_staff_authority'
      and not tgisinternal
      and tgenabled <> 'D'
  ) then
    raise exception 'Staff authority guard trigger is absent';
  end if;

  if not has_function_privilege('authenticated', 'public.pb_inventory_reference_prices()', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.pb_set_inventory_reference_prices(uuid,numeric,numeric)', 'EXECUTE')
     or has_function_privilege('anon', 'public.pb_inventory_reference_prices()', 'EXECUTE')
     or has_function_privilege('anon', 'public.pb_set_inventory_reference_prices(uuid,numeric,numeric)', 'EXECUTE') then
    raise exception 'Inventory reference-price RPC grants are incorrect';
  end if;
end;
$$;

select
  'Inventory reference-price access checks passed' as result,
  false as inventory_values_changed,
  false as purchase_values_changed;

-- Review any other public views that mention these fields. View ownership and
-- security settings determine whether they can bypass the table boundary.
select schemaname, viewname
from pg_views
where schemaname = 'public'
  and (definition ilike '%pb_inventory%')
  and (definition ilike '%purchase_price%'
       or definition ilike '%buying_price%')
order by viewname;
