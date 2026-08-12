-- Wamama Pamoja Enterprise
-- Loan deposits / prepayments setup.
-- Run this complete file in the Wamama Supabase SQL Editor.
--
-- Purpose:
-- 1. Keep ordinary member savings separate from loan deposits / prepayments.
-- 2. When a repayment is above the remaining loan balance, only the balance is applied to the loan.
-- 3. The extra amount is held in pb_excess_payments as a pending loan deposit / prepayment.
-- 4. This file does not rewrite historical savings or old resolved records.

begin;

create extension if not exists pgcrypto;

alter table public.pb_permissions
  add column if not exists can_manage_excess_payments boolean not null default false;

create table if not exists public.pb_excess_payments (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  member_id text not null,
  group_id text,
  loan_id text not null,
  original_repayment_id text,
  payment_date date not null default current_date,
  original_payment_amount numeric(14,2) not null default 0,
  amount_applied_to_loan numeric(14,2) not null default 0,
  excess_amount numeric(14,2) not null check (excess_amount > 0),
  status text not null default 'pending'
    check (status in ('pending','transferred_to_savings','refunded','applied_to_loan')),
  source text not null default 'repayment',
  notes text,
  resolution_reference text,
  resolved_at timestamptz,
  resolved_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists pb_excess_payments_original_repayment_uidx
  on public.pb_excess_payments (original_repayment_id)
  where original_repayment_id is not null;

create index if not exists pb_excess_payments_business_status_idx
  on public.pb_excess_payments (business_id, status, created_at desc);

create index if not exists pb_excess_payments_member_idx
  on public.pb_excess_payments (member_id, created_at desc);

create or replace function public.pb_current_staff_id_text()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select s.id::text
  from public.pb_staff s
  where s.auth_user_id = auth.uid()
    and lower(coalesce(s.status, 'active')) = 'active'
  limit 1
$$;

create or replace function public.pb_current_business_id_text()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select s.business_id::text
  from public.pb_staff s
  where s.auth_user_id = auth.uid()
    and lower(coalesce(s.status, 'active')) = 'active'
  limit 1
$$;

create or replace function public.pb_can_manage_excess_payments()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(bool_or(
    lower(coalesce(s.role, '')) in ('admin','ceo')
    or coalesce(p.can_manage_excess_payments, false)
  ), false)
  from public.pb_staff s
  left join public.pb_permissions p on p.staff_id::text = s.id::text
  where s.auth_user_id = auth.uid()
    and lower(coalesce(s.status, 'active')) = 'active'
$$;

alter table public.pb_excess_payments enable row level security;

drop policy if exists pb_excess_payments_select on public.pb_excess_payments;
create policy pb_excess_payments_select
on public.pb_excess_payments
for select
to authenticated
using (
  business_id = public.pb_current_business_id_text()
  and public.pb_can_manage_excess_payments()
);

drop policy if exists pb_excess_payments_insert on public.pb_excess_payments;
create policy pb_excess_payments_insert
on public.pb_excess_payments
for insert
to authenticated
with check (
  business_id = public.pb_current_business_id_text()
  and public.pb_can_manage_excess_payments()
);

drop policy if exists pb_excess_payments_update on public.pb_excess_payments;
create policy pb_excess_payments_update
on public.pb_excess_payments
for update
to authenticated
using (
  business_id = public.pb_current_business_id_text()
  and public.pb_can_manage_excess_payments()
)
with check (
  business_id = public.pb_current_business_id_text()
  and public.pb_can_manage_excess_payments()
);

grant select, insert, update on public.pb_excess_payments to authenticated;

create or replace function public.pb_capture_repayment_excess()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  loan_row record;
  already_applied numeric;
  remaining numeric;
  applied numeric;
  excess numeric;
  principal_share numeric;
  existing_excess_status text;
begin
  if lower(coalesce(new.status, 'approved')) in ('pending','rejected','cancelled') then
    return new;
  end if;

  select l.id, l.business_id, l.member_id, l.group_id, l.total_payable
  into loan_row
  from public.pb_loans l
  where l.id::text = new.loan_id::text
  for update;

  if not found or coalesce(loan_row.total_payable, 0) <= 0 then
    return new;
  end if;

  select coalesce(sum(r.amount), 0)
  into already_applied
  from public.pb_repayments r
  where r.loan_id::text = new.loan_id::text
    and r.id::text <> new.id::text
    and lower(coalesce(r.status, 'approved')) not in ('pending','rejected','cancelled');

  remaining := greatest(0, loan_row.total_payable - already_applied);
  applied := greatest(0, least(coalesce(new.amount, 0), remaining));
  excess := greatest(0, coalesce(new.amount, 0) - applied);

  select ep.status into existing_excess_status
  from public.pb_excess_payments ep
  where ep.original_repayment_id = new.id::text
  limit 1;

  if existing_excess_status is not null and existing_excess_status <> 'pending' then
    raise exception 'This repayment already has a resolved loan deposit / prepayment record and can no longer be edited.';
  end if;

  if excess <= 0 then
    delete from public.pb_excess_payments
    where original_repayment_id = new.id::text and status = 'pending';
    return new;
  end if;

  insert into public.pb_excess_payments (
    business_id, member_id, group_id, loan_id, original_repayment_id,
    payment_date, original_payment_amount, amount_applied_to_loan,
    excess_amount, status, source, notes
  ) values (
    loan_row.business_id::text,
    loan_row.member_id::text,
    loan_row.group_id::text,
    loan_row.id::text,
    new.id::text,
    coalesce(new.meeting_date, new.created_at::date, current_date),
    new.amount,
    applied,
    excess,
    'pending',
    'repayment',
    'Automatically held as a loan deposit / prepayment because the payment exceeded the remaining loan balance.'
  )
  on conflict (original_repayment_id) where original_repayment_id is not null do update
  set payment_date = excluded.payment_date,
      original_payment_amount = excluded.original_payment_amount,
      amount_applied_to_loan = excluded.amount_applied_to_loan,
      excess_amount = excluded.excess_amount,
      notes = excluded.notes,
      updated_at = now()
  where public.pb_excess_payments.status = 'pending';

  if applied <= 0 then
    new.status := 'rejected';
    new.edit_notes := concat_ws(' | ', nullif(new.edit_notes, ''),
      'Full payment held as a loan deposit / prepayment because the loan was already cleared.');
    return new;
  end if;

  principal_share := case
    when coalesce(new.amount, 0) > 0 then coalesce(new.principal, 0) / new.amount
    else 1
  end;

  new.amount := round(applied, 2);
  new.principal := round(applied * principal_share, 2);
  new.interest := round(applied - new.principal, 2);
  new.edit_notes := concat_ws(' | ', nullif(new.edit_notes, ''),
    'Excess of KES ' || round(excess, 2) || ' held as loan deposit / prepayment.');

  return new;
end;
$$;

create or replace function public.pb_protect_excess_source_repayment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1 from public.pb_excess_payments ep
    where ep.original_repayment_id = old.id::text
  ) then
    raise exception 'This repayment has a loan deposit / prepayment record and cannot be deleted. Resolve or correct it from the loan deposit / prepayment records.';
  end if;
  return old;
end;
$$;

drop trigger if exists pb_capture_repayment_excess_trigger on public.pb_repayments;
create trigger pb_capture_repayment_excess_trigger
before insert or update of amount, status
on public.pb_repayments
for each row
execute function public.pb_capture_repayment_excess();

drop trigger if exists pb_protect_excess_source_repayment_trigger on public.pb_repayments;
create trigger pb_protect_excess_source_repayment_trigger
before delete on public.pb_repayments
for each row
execute function public.pb_protect_excess_source_repayment();

commit;

select
  'Wamama loan deposit / prepayment setup ready' as result,
  count(*) filter (where status = 'pending') as open_prepayment_rows,
  count(*) filter (where status = 'transferred_to_savings') as already_moved_to_savings_rows,
  false as historical_savings_changed
from public.pb_excess_payments;
