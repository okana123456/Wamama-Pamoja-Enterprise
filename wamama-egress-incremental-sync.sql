-- Wamama Pamoja Enterprise
-- Low-egress incremental synchronization support.
--
-- This file does not delete, archive, reclassify or recalculate business data.
-- It adds an updated_at marker and supporting indexes so the application can
-- request only rows that changed since a device's previous successful sync.

begin;

create or replace function public.pb_touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare
  v_table_name text;
  has_created_at boolean;
  has_business_id boolean;
begin
  foreach v_table_name in array array[
    'pb_groups', 'pb_members', 'pb_guarantors', 'pb_staff',
    'pb_inventory', 'pb_loans', 'pb_orders', 'pb_savings',
    'pb_repayments', 'pb_excess_payments', 'pb_meetings',
    'pb_suppliers', 'pb_purchases', 'pb_purchase_lines',
    'pb_reconciliations', 'pb_expenses'
  ]
  loop
    if to_regclass('public.' || v_table_name) is null then
      continue;
    end if;

    execute format(
      'alter table public.%I add column if not exists updated_at timestamptz',
      v_table_name
    );

    select exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and information_schema.columns.table_name = v_table_name
        and column_name = 'created_at'
    ) into has_created_at;

    if has_created_at then
      execute format(
        'update public.%I set updated_at = coalesce(created_at, now()) where updated_at is null',
        v_table_name
      );
    else
      execute format(
        'update public.%I set updated_at = now() where updated_at is null',
        v_table_name
      );
    end if;

    execute format(
      'alter table public.%I alter column updated_at set default now()',
      v_table_name
    );
    execute format(
      'alter table public.%I alter column updated_at set not null',
      v_table_name
    );

    execute format(
      'drop trigger if exists pb_touch_updated_at_trigger on public.%I',
      v_table_name
    );
    execute format(
      'create trigger pb_touch_updated_at_trigger before update on public.%I for each row execute function public.pb_touch_updated_at()',
      v_table_name
    );

    select exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and information_schema.columns.table_name = v_table_name
        and column_name = 'business_id'
    ) into has_business_id;

    if has_business_id then
      execute format(
        'create index if not exists %I on public.%I (business_id, updated_at desc)',
        v_table_name || '_business_updated_idx',
        v_table_name
      );
    else
      execute format(
        'create index if not exists %I on public.%I (updated_at desc)',
        v_table_name || '_updated_idx',
        v_table_name
      );
    end if;
  end loop;
end;
$$;

commit;

select
  'Wamama incremental synchronization is ready' as result,
  count(*) as tracked_tables,
  false as business_data_deleted,
  false as financial_values_changed
from information_schema.columns
where table_schema = 'public'
  and column_name = 'updated_at'
  and table_name = any(array[
    'pb_groups', 'pb_members', 'pb_guarantors', 'pb_staff',
    'pb_inventory', 'pb_loans', 'pb_orders', 'pb_savings',
    'pb_repayments', 'pb_excess_payments', 'pb_meetings',
    'pb_suppliers', 'pb_purchases', 'pb_purchase_lines',
    'pb_reconciliations', 'pb_expenses'
  ]);
