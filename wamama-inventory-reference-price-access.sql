-- Wamama Pamoja: keep inventory reference prices under management control.
-- Run after wamama-inventory-cost-separation.sql, and deploy with the matching
-- client change that selects only safe inventory columns. This migration is
-- transactional and does not change existing inventory or purchase prices.
--
-- Inventory purchase_price = confidential supplier/wholesale reference price.
-- Inventory buying_price = confidential weighted stock valuation cost.
-- Purchase-line cost_per_unit remains a separate, visible transaction price.

begin;

do $$
begin
  if not exists (
    select 1 from pg_class c
    where c.oid = 'public.pb_inventory'::regclass and c.relrowsecurity
  ) then
    raise exception 'Enable and configure tenant RLS on pb_inventory before installing price access controls';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'pb_inventory'
      and policyname = 'Tenant Isolation'
  ) then
    raise exception 'The pb_inventory Tenant Isolation policy is required before installing price access controls';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'pb_inventory'
      and column_name = 'purchase_price'
  ) then
    raise exception 'Run wamama-inventory-cost-separation.sql first';
  end if;

  -- A full-row change event would disclose the protected columns. Inventory
  -- stays available through normal reads and explicit refreshes. Do not add it
  -- back to the publication unless the publication itself excludes both prices.
  if exists (
    select 1 from pg_publication
    where pubname = 'supabase_realtime' and puballtables
  ) then
    raise exception 'supabase_realtime publishes all tables; configure a publication excluding pb_inventory before continuing';
  end if;

  if exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'pb_inventory'
  ) then
    alter publication supabase_realtime drop table public.pb_inventory;
  end if;
end;
$$;

-- New assets can be created by procurement without assigning a confidential
-- valuation cost. Management can set that cost with the RPC below.
alter table public.pb_inventory alter column buying_price set default 0;

-- The price RPCs trust the staff role stored in pb_staff. A tenant-wide staff
-- policy must not let an officer promote that role through the table API.
-- The existing registration and staff-auth RPCs execute as their database
-- owner; direct browser writes execute as authenticated/anon.
create or replace function public.pb_guard_staff_authority()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_manager_business public.pb_staff.business_id%type;
begin
  if current_user not in ('authenticated', 'anon') then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  select s.business_id into v_manager_business
  from public.pb_staff s
  where s.auth_user_id = (select auth.uid())
    and s.status = 'active'
    and s.role in ('admin', 'ceo')
  limit 1;

  if tg_op = 'INSERT' then
    if v_manager_business is null or new.business_id is distinct from v_manager_business then
      raise exception 'Only administration may create staff accounts'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if v_manager_business is null or old.business_id is distinct from v_manager_business then
      raise exception 'Only administration may delete staff accounts'
        using errcode = '42501';
    end if;
    return old;
  end if;

  if new.role is distinct from old.role
     or new.status is distinct from old.status
     or new.auth_user_id is distinct from old.auth_user_id
     or new.business_id is distinct from old.business_id
     or new.id is distinct from old.id then
    if v_manager_business is null
       or old.business_id is distinct from v_manager_business
       or new.business_id is distinct from v_manager_business then
      raise exception 'Only administration may change staff authority'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists pb_guard_staff_authority on public.pb_staff;
create trigger pb_guard_staff_authority
before insert or update or delete on public.pb_staff
for each row execute function public.pb_guard_staff_authority();

-- Supabase users share the authenticated database role. A table-level grant
-- overrides a column-level revoke, so replace broad grants with safe columns.
revoke select, insert, update on table public.pb_inventory
  from public, anon, authenticated;
revoke select (purchase_price, buying_price),
       insert (purchase_price, buying_price),
       update (purchase_price, buying_price)
  on table public.pb_inventory from public, anon, authenticated;

do $$
declare
  v_safe_columns text;
begin
  select string_agg(format('%I', a.attname), ', ' order by a.attnum)
    into v_safe_columns
  from pg_attribute a
  where a.attrelid = 'public.pb_inventory'::regclass
    and a.attnum > 0 and not a.attisdropped
    and a.attname not in ('purchase_price', 'buying_price');

  if v_safe_columns is null then
    raise exception 'No safe pb_inventory columns found';
  end if;

  execute format('grant select (%s) on table public.pb_inventory to authenticated', v_safe_columns);
  execute format('grant insert (%s) on table public.pb_inventory to authenticated', v_safe_columns);
  execute format('grant update (%s) on table public.pb_inventory to authenticated', v_safe_columns);
end;
$$;

-- Defense in depth if someone later restores a table-wide grant. It also keeps
-- the visible loan/selling price manager-controlled. Direct SQL maintenance by
-- postgres and trusted service-role jobs remains possible.
create or replace function public.pb_guard_inventory_reference_prices()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_changed boolean;
begin
  if tg_op = 'INSERT' then
    v_changed := new.purchase_price is not null
      or new.buying_price is distinct from 0
      or new.loan_price is distinct from 0;
  else
    v_changed := new.purchase_price is distinct from old.purchase_price
      or new.buying_price is distinct from old.buying_price
      or new.loan_price is distinct from old.loan_price;
  end if;

  if not v_changed then
    return new;
  end if;

  if (select auth.role()) = 'service_role'
     or ((select auth.role()) is null and session_user = 'postgres') then
    return new;
  end if;

  if not exists (
    select 1 from public.pb_staff s
    where s.auth_user_id = (select auth.uid())
      and s.status = 'active'
      and s.role in ('admin', 'ceo', 'branch_manager')
      and s.business_id = new.business_id
  ) then
    raise exception 'Only management may change inventory reference or loan prices'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists pb_guard_inventory_reference_prices on public.pb_inventory;
create trigger pb_guard_inventory_reference_prices
before insert or update on public.pb_inventory
for each row execute function public.pb_guard_inventory_reference_prices();

-- The browser calls this only for management after its safe inventory load.
-- This RPC checks the actual authenticated staff row and returns only that
-- staff member's business. A caller cannot choose a business ID.
create or replace function public.pb_inventory_reference_prices()
returns table (id uuid, purchase_price numeric, buying_price numeric)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_business_id public.pb_staff.business_id%type;
begin
  select s.business_id into v_business_id
  from public.pb_staff s
  where s.auth_user_id = (select auth.uid())
    and s.status = 'active'
    and s.role in ('admin', 'ceo', 'branch_manager')
  limit 1;

  if v_business_id is null then
    raise exception 'Only management may view inventory reference prices'
      using errcode = '42501';
  end if;

  return query
    select i.id::uuid, i.purchase_price::numeric, i.buying_price::numeric
    from public.pb_inventory i
    where i.business_id = v_business_id;
end;
$$;

-- A manager deliberately edits both reference values from the Inventory form.
-- Receipt entry by procurement does not call this function.
create or replace function public.pb_set_inventory_reference_prices(
  p_inventory_id uuid,
  p_purchase_price numeric,
  p_buying_price numeric
)
returns table (id uuid, purchase_price numeric, buying_price numeric)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_business_id public.pb_staff.business_id%type;
begin
  if p_inventory_id is null
     or p_buying_price is null or p_buying_price < 0
     or (p_purchase_price is not null and p_purchase_price < 0)
     or p_buying_price::text in ('NaN', 'Infinity', '-Infinity')
     or p_purchase_price::text in ('NaN', 'Infinity', '-Infinity') then
    raise exception 'Enter valid nonnegative inventory reference prices'
      using errcode = '22023';
  end if;

  select s.business_id into v_business_id
  from public.pb_staff s
  where s.auth_user_id = (select auth.uid())
    and s.status = 'active'
    and s.role in ('admin', 'ceo', 'branch_manager')
  limit 1;

  if v_business_id is null then
    raise exception 'Only management may change inventory reference prices'
      using errcode = '42501';
  end if;

  return query
    update public.pb_inventory as i
    set purchase_price = p_purchase_price,
        buying_price = p_buying_price
    where i.id = p_inventory_id and i.business_id = v_business_id
    returning i.id::uuid, i.purchase_price::numeric, i.buying_price::numeric;

  if not found then
    raise exception 'Inventory asset not found in your business'
      using errcode = 'P0002';
  end if;
end;
$$;

-- Functions otherwise default to EXECUTE for PUBLIC in PostgreSQL.
revoke all on function public.pb_guard_inventory_reference_prices()
  from public, anon, authenticated;
revoke all on function public.pb_guard_staff_authority()
  from public, anon, authenticated;
revoke all on function public.pb_inventory_reference_prices()
  from public, anon, authenticated;
revoke all on function public.pb_set_inventory_reference_prices(uuid, numeric, numeric)
  from public, anon, authenticated;
grant execute on function public.pb_inventory_reference_prices()
  to authenticated;
grant execute on function public.pb_set_inventory_reference_prices(uuid, numeric, numeric)
  to authenticated;

commit;
