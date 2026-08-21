-- Wamama Pamoja Enterprise
-- Allow several different inventory items for one client in the same
-- approved Sold Items Form while preserving the normal one-active-loan rule.
-- Run this complete file once in the Wamama Supabase SQL Editor.

begin;

-- Preserve the current non-system loan trigger definitions for audit/recovery.
create table if not exists public.pb_loan_trigger_backup_20260821 (
  trigger_name text primary key,
  function_name text not null,
  trigger_definition text not null,
  backed_up_at timestamptz not null default now()
);

insert into public.pb_loan_trigger_backup_20260821
  (trigger_name, function_name, trigger_definition)
select
  t.tgname,
  p.proname,
  pg_get_triggerdef(t.oid, true)
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
join pg_proc p on p.oid = t.tgfoid
where n.nspname = 'public'
  and c.relname = 'pb_loans'
  and not t.tgisinternal
  and p.proname = 'prevent_multiple_active_loans'
on conflict (trigger_name) do nothing;

-- Remove only the legacy trigger that blocks every second active loan.
-- Its definition remains in the backup table above.
do $$
declare
  v_trigger record;
begin
  for v_trigger in
    select t.tgname
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_proc p on p.oid = t.tgfoid
    where n.nspname = 'public'
      and c.relname = 'pb_loans'
      and not t.tgisinternal
      and p.proname = 'prevent_multiple_active_loans'
  loop
    execute format('drop trigger if exists %I on public.pb_loans', v_trigger.tgname);
  end loop;
end;
$$;

create or replace function public.pb_validate_wamama_active_loan_rules()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_is_sold_form boolean := false;
begin
  if lower(coalesce(new.status::text, '')) <> 'active' or new.member_id is null then
    return new;
  end if;

  if new.order_id is not null then
    select coalesce(o.notes, '') like '%"source":"sold_items"%'
      into v_is_sold_form
    from public.pb_orders o
    where o.id::text = new.order_id::text
    limit 1;
  end if;
  v_is_sold_form := coalesce(v_is_sold_form, false);

  -- Several different items are allowed only when both loans were submitted
  -- together in the same Sold Items Form.
  if v_is_sold_form and new.order_id is not null then
    if exists (
      select 1 from public.pb_loans l
      where l.business_id::text = new.business_id::text
        and l.member_id::text = new.member_id::text
        and l.id is distinct from new.id
        and lower(coalesce(l.status::text, '')) = 'active'
        and l.order_id::text = new.order_id::text
        and coalesce(l.asset_id::text, '') = coalesce(new.asset_id::text, '')
        and coalesce(l.asset_name, '') = coalesce(new.asset_name, '')
    ) then
      raise exception 'This client already has the same item in this Sold Items Form. Increase quantity instead of creating a duplicate loan.';
    end if;

    if exists (
      select 1 from public.pb_loans l
      where l.business_id::text = new.business_id::text
        and l.member_id::text = new.member_id::text
        and l.id is distinct from new.id
        and lower(coalesce(l.status::text, '')) = 'active'
        and l.order_id::text is distinct from new.order_id::text
    ) then
      raise exception 'This client already has an unrelated active loan. Clear it before approving this Sold Items Form.';
    end if;

    return new;
  end if;

  if exists (
    select 1 from public.pb_loans l
    where l.business_id::text = new.business_id::text
      and l.member_id::text = new.member_id::text
      and l.id is distinct from new.id
      and lower(coalesce(l.status::text, '')) = 'active'
  ) then
    raise exception 'This client already has an active loan. Multiple loans are allowed only for different items submitted together in one Sold Items Form.';
  end if;

  return new;
end;
$$;

drop trigger if exists pb_validate_wamama_active_loan_rules_trigger on public.pb_loans;
create trigger pb_validate_wamama_active_loan_rules_trigger
before insert or update of status, member_id, order_id, asset_id on public.pb_loans
for each row execute function public.pb_validate_wamama_active_loan_rules();

commit;

select
  'Wamama sold-form multiple-item loans are ready' as result,
  (select count(*) from public.pb_loan_trigger_backup_20260821) as legacy_triggers_backed_up,
  (select count(*) from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='pb_loans'
      and t.tgname='pb_validate_wamama_active_loan_rules_trigger'
      and not t.tgisinternal) as new_rule_triggers_active,
  false as existing_loans_changed,
  false as balances_changed,
  false as repayments_changed;
