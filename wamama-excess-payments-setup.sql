-- Wamama Pamoja Enterprise
-- Excess payment ledger, automatic future loan allocation and permissions.
-- Run this complete file once in the Wamama Supabase SQL Editor.
-- This setup intentionally does NOT reclassify historical repayments.

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

-- Enforce the same allocation rule for every future insert and approval route.
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
    raise exception 'This repayment already has a resolved excess payment and can no longer be edited.';
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
    'Automatically separated because the payment exceeded the remaining loan balance.'
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
      'Full payment moved to Excess Payments because the loan was already cleared.');
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
    'Excess of KES ' || round(excess, 2) || ' moved to Excess Payments.');
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
    raise exception 'This repayment has an excess-payment record and cannot be deleted. Resolve or correct it through Excess Payments.';
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

create or replace function public.pb_resolve_excess_to_savings(
  p_excess_id uuid,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  ex public.pb_excess_payments%rowtype;
  member_row public.pb_members%rowtype;
  staff_row public.pb_staff%rowtype;
begin
  if not public.pb_can_manage_excess_payments() then
    raise exception 'You do not have permission to manage excess payments.';
  end if;

  select * into ex from public.pb_excess_payments
  where id = p_excess_id and business_id = public.pb_current_business_id_text()
  for update;
  if not found then raise exception 'Excess payment not found.'; end if;
  if ex.status <> 'pending' then raise exception 'This excess payment has already been resolved.'; end if;

  select * into member_row from public.pb_members where id::text = ex.member_id limit 1;
  select * into staff_row from public.pb_staff where id::text = public.pb_current_staff_id_text() limit 1;
  if member_row.id is null then raise exception 'Member record not found.'; end if;

  insert into public.pb_savings (
    business_id, member_id, group_id, meeting_date, amount,
    recorded_by, notes, status
  ) values (
    member_row.business_id, member_row.id, member_row.group_id,
    current_date, ex.excess_amount, staff_row.id,
    concat('Excess loan payment transferred to savings. ', coalesce(p_note, '')),
    'approved'
  );

  update public.pb_excess_payments
  set status = 'transferred_to_savings', resolved_at = now(),
      resolved_by = staff_row.id::text, notes = concat_ws(' | ', notes, nullif(p_note, '')),
      updated_at = now()
  where id = ex.id;
end;
$$;

create or replace function public.pb_resolve_excess_as_refund(
  p_excess_id uuid,
  p_reference text,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  ex public.pb_excess_payments%rowtype;
begin
  if not public.pb_can_manage_excess_payments() then
    raise exception 'You do not have permission to manage excess payments.';
  end if;
  if nullif(trim(coalesce(p_reference, '')), '') is null then
    raise exception 'A refund reference is required.';
  end if;

  select * into ex from public.pb_excess_payments
  where id = p_excess_id and business_id = public.pb_current_business_id_text()
  for update;
  if not found then raise exception 'Excess payment not found.'; end if;
  if ex.status <> 'pending' then raise exception 'This excess payment has already been resolved.'; end if;

  update public.pb_excess_payments
  set status = 'refunded', resolution_reference = trim(p_reference),
      resolved_at = now(), resolved_by = public.pb_current_staff_id_text(),
      notes = concat_ws(' | ', notes, nullif(p_note, '')), updated_at = now()
  where id = ex.id;
end;
$$;

create or replace function public.pb_resolve_excess_to_loan(
  p_excess_id uuid,
  p_loan_id text,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  ex public.pb_excess_payments%rowtype;
  target_loan public.pb_loans%rowtype;
  staff_row public.pb_staff%rowtype;
  already_paid numeric;
  remaining numeric;
  interest_ratio numeric;
  principal_amount numeric;
begin
  if not public.pb_can_manage_excess_payments() then
    raise exception 'You do not have permission to manage excess payments.';
  end if;

  select * into ex from public.pb_excess_payments
  where id = p_excess_id and business_id = public.pb_current_business_id_text()
  for update;
  if not found then raise exception 'Excess payment not found.'; end if;
  if ex.status <> 'pending' then raise exception 'This excess payment has already been resolved.'; end if;

  select * into target_loan from public.pb_loans
  where id::text = p_loan_id
    and business_id::text = ex.business_id
    and member_id::text = ex.member_id
    and lower(coalesce(status, '')) = 'active'
  for update;
  if target_loan.id is null then raise exception 'Eligible active loan not found for this member.'; end if;

  select coalesce(sum(amount), 0) into already_paid
  from public.pb_repayments
  where loan_id::text = target_loan.id::text
    and lower(coalesce(status, 'approved')) not in ('pending','rejected','cancelled');
  remaining := greatest(0, target_loan.total_payable - already_paid);
  if ex.excess_amount > remaining then
    raise exception 'The selected loan balance is only KES %, which is less than this excess payment.', round(remaining, 2);
  end if;

  select * into staff_row from public.pb_staff where id::text = public.pb_current_staff_id_text() limit 1;
  interest_ratio := case when target_loan.total_payable > 0
    then (target_loan.total_payable - target_loan.loan_value) / target_loan.total_payable else 0 end;
  principal_amount := round(ex.excess_amount * (1 - interest_ratio), 2);

  insert into public.pb_repayments (
    business_id, loan_id, member_id, group_id, meeting_date, amount,
    principal, interest, recorded_by, status, notes
  ) values (
    target_loan.business_id, target_loan.id, target_loan.member_id, target_loan.group_id,
    current_date, ex.excess_amount, principal_amount,
    round(ex.excess_amount - principal_amount, 2), staff_row.id, 'approved',
    concat('Applied from excess payment ledger. ', coalesce(p_note, ''))
  );

  update public.pb_excess_payments
  set status = 'applied_to_loan', resolution_reference = target_loan.id::text,
      resolved_at = now(), resolved_by = staff_row.id::text,
      notes = concat_ws(' | ', notes, nullif(p_note, '')), updated_at = now()
  where id = ex.id;
end;
$$;

grant execute on function public.pb_resolve_excess_to_savings(uuid, text) to authenticated;
grant execute on function public.pb_resolve_excess_as_refund(uuid, text, text) to authenticated;
grant execute on function public.pb_resolve_excess_to_loan(uuid, text, text) to authenticated;

commit;

-- Verification output. It should be empty immediately after installation because
-- historical repayments are deliberately left unchanged.
select
  status,
  count(*) as entries,
  round(coalesce(sum(excess_amount), 0), 2) as total_excess
from public.pb_excess_payments
group by status
order by status;
