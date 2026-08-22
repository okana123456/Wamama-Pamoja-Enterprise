-- Wamama Pamoja Enterprise
-- RLS/access-policy performance and tenant-isolation correction.
--
-- Safe effects:
--   * No business rows or financial values are inserted, updated or deleted.
--   * Existing role permissions remain in place.
--   * Current-business and billing helpers are evaluated once per query.
--   * Billing guard policies become RESTRICTIVE so they combine with tenant
--     isolation using AND, rather than accidentally broadening access with OR.

begin;

-- Keep a metadata snapshot for review/support. This contains policy text only.
create table if not exists public.pb_rls_policy_backup_20260822 as
select now() as captured_at, p.*
from pg_policies p
where p.schemaname = 'public'
  and p.tablename like 'pb\_%' escape '\';

do $$
declare
  r record;
begin
  -- Rebuild the standard tenant policies with an InitPlan wrapper. The scalar
  -- SELECT prevents get_my_business_id() from scanning pb_staff for every row.
  for r in
    select tablename
    from pg_policies
    where schemaname = 'public'
      and policyname = 'Tenant Isolation'
  loop
    execute format('drop policy %I on public.%I', 'Tenant Isolation', r.tablename);

    if r.tablename = 'pb_settings' then
      execute format(
        'create policy %I on public.%I as permissive for all to authenticated using (id = (''biz_''::text || (select public.get_my_business_id())::text)) with check (id = (''biz_''::text || (select public.get_my_business_id())::text))',
        'Tenant Isolation', r.tablename
      );
    elsif r.tablename = 'pb_permissions' then
      execute format(
        'create policy %I on public.%I as permissive for all to authenticated using (staff_id in (select s.id from public.pb_staff s where s.business_id = (select public.get_my_business_id())))',
        'Tenant Isolation', r.tablename
      );
    else
      execute format(
        'create policy %I on public.%I as permissive for all to authenticated using (business_id = (select public.get_my_business_id())) with check (business_id = (select public.get_my_business_id()))',
        'Tenant Isolation', r.tablename
      );
    end if;
  end loop;

  -- A restrictive billing policy is combined with tenant isolation using AND.
  -- Non-admin roles still pass this function exactly as before; an unpaid admin
  -- is blocked without granting access to another business.
  for r in
    select tablename
    from pg_policies
    where schemaname = 'public'
      and policyname = 'admin billing guard'
  loop
    execute format('drop policy %I on public.%I', 'admin billing guard', r.tablename);
    execute format(
      'create policy %I on public.%I as restrictive for all to authenticated using ((select public.pb_admin_billing_open_for_current_user())) with check ((select public.pb_admin_billing_open_for_current_user()))',
      'admin billing guard', r.tablename
    );
  end loop;
end
$$;

-- Optimize the two billing read policies. Their meaning is unchanged.
do $$
begin
  if to_regclass('public.pb_billing_cycles') is not null then
    drop policy if exists "billing cycles readable by own business" on public.pb_billing_cycles;
    create policy "billing cycles readable by own business"
      on public.pb_billing_cycles
      as permissive
      for select
      to authenticated
      using (business_id = (select public.get_my_business_id()));
  end if;

  if to_regclass('public.pb_billing_transactions') is not null then
    drop policy if exists "billing transactions readable by own business" on public.pb_billing_transactions;
    create policy "billing transactions readable by own business"
      on public.pb_billing_transactions
      as permissive
      for select
      to authenticated
      using (business_id = (select public.get_my_business_id()));
  end if;
end
$$;

-- These admin-only ledgers keep their existing permissions while evaluating
-- the current user/business helpers once per statement instead of once per row.
do $$
begin
  if to_regclass('public.pb_excess_payments') is not null then
    drop policy if exists pb_excess_payments_insert on public.pb_excess_payments;
    drop policy if exists pb_excess_payments_select on public.pb_excess_payments;
    drop policy if exists pb_excess_payments_update on public.pb_excess_payments;

    create policy pb_excess_payments_insert on public.pb_excess_payments
      as permissive for insert to authenticated
      with check (
        business_id = (select public.pb_current_business_id_text())
        and (select public.pb_can_manage_excess_payments())
      );
    create policy pb_excess_payments_select on public.pb_excess_payments
      as permissive for select to authenticated
      using (
        business_id = (select public.pb_current_business_id_text())
        and (select public.pb_can_manage_excess_payments())
      );
    create policy pb_excess_payments_update on public.pb_excess_payments
      as permissive for update to authenticated
      using (
        business_id = (select public.pb_current_business_id_text())
        and (select public.pb_can_manage_excess_payments())
      )
      with check (
        business_id = (select public.pb_current_business_id_text())
        and (select public.pb_can_manage_excess_payments())
      );
  end if;

  if to_regclass('public.pb_prepayment_releases') is not null then
    drop policy if exists pb_prepayment_releases_select on public.pb_prepayment_releases;
    create policy pb_prepayment_releases_select on public.pb_prepayment_releases
      as permissive for select to authenticated
      using (
        business_id = (select public.pb_current_business_id_text())
        and (select public.pb_can_manage_excess_payments())
      );
  end if;
end
$$;

commit;

analyze public.pb_staff;
analyze public.pb_permissions;
analyze public.pb_billing_cycles;

select
  'Wamama RLS access optimization is ready' as result,
  count(*) filter (where policyname = 'Tenant Isolation') as tenant_policies_optimized,
  count(*) filter (
    where policyname = 'admin billing guard'
      and upper(permissive) = 'RESTRICTIVE'
  ) as restrictive_billing_guards,
  false as business_data_changed,
  false as financial_values_changed
from pg_policies
where schemaname = 'public'
  and tablename like 'pb\_%' escape '\';
