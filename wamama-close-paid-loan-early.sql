-- Wamama Pamoja Enterprise: settle a paid loan before its scheduled end.
-- Run once in the Wamama Supabase SQL Editor before deploying the menu option.
-- This file installs the option only; it changes no existing loan or cash row.
-- It uses only unused deposits paid on the selected loan, never another loan.

begin;

create table if not exists public.pb_early_loan_closure_allocations (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  loan_id text not null,
  member_id text not null,
  prepayment_id text not null,
  repayment_id text not null unique,
  amount numeric(14,2) not null check (amount > 0),
  closed_by_staff_id text not null,
  created_at timestamptz not null default now()
);

alter table public.pb_early_loan_closure_allocations enable row level security;

drop policy if exists pb_early_loan_closure_allocations_read
  on public.pb_early_loan_closure_allocations;
create policy pb_early_loan_closure_allocations_read
  on public.pb_early_loan_closure_allocations for select to authenticated
  using (business_id = public.pb_current_business_id_text()
         and public.pb_can_manage_excess_payments());

grant select on public.pb_early_loan_closure_allocations to authenticated;
revoke all on public.pb_early_loan_closure_allocations from anon;

create or replace function public.pb_close_paid_loan_early(p_loan_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan public.pb_loans%rowtype;
  v_deposit public.pb_excess_payments%rowtype;
  v_business_id text;
  v_staff_id text;
  v_today date := (now() at time zone 'Africa/Nairobi')::date;
  v_paid numeric := 0;
  v_balance numeric := 0;
  v_available numeric := 0;
  v_use numeric := 0;
  v_applied numeric := 0;
  v_principal numeric := 0;
  v_repayment_id text;
  v_recorded_by public.pb_repayments.recorded_by%type;
begin
  if not public.pb_can_manage_excess_payments() then
    raise exception 'Only an authorized manager can close a paid loan early.';
  end if;
  v_business_id := public.pb_current_business_id_text();
  v_staff_id := public.pb_current_staff_id_text();
  if nullif(v_business_id, '') is null or nullif(v_staff_id, '') is null then
    raise exception 'No active Wamama staff session was found.';
  end if;

  select * into v_loan from public.pb_loans l
  where l.id::text = p_loan_id and l.business_id::text = v_business_id
  for update;
  if not found then raise exception 'Loan not found for this business.'; end if;
  if lower(coalesce(v_loan.status::text, '')) = 'completed' then
    return jsonb_build_object('success', true, 'status', 'completed',
      'loan_id', v_loan.id::text, 'applied_deposit', 0);
  end if;
  if lower(coalesce(v_loan.status::text, '')) <> 'active'
     or coalesce(v_loan.total_payable, 0) <= 0 then
    raise exception 'Only an active loan with a valid payable balance can be closed.';
  end if;

  select coalesce(sum(r.amount), 0) into v_paid
  from public.pb_repayments r
  where r.business_id::text = v_business_id
    and r.loan_id::text = p_loan_id
    and r.voided_at is null
    and lower(coalesce(r.status::text, 'approved'))
      not in ('pending', 'rejected', 'cancelled', 'voided')
    and coalesce(r.meeting_date, (r.created_at at time zone 'Africa/Nairobi')::date) <= v_today;
  v_balance := round(greatest(0, v_loan.total_payable - v_paid), 2);

  if v_balance > 0.01 then
    select coalesce(sum(greatest(0, ep.excess_amount - coalesce(ep.released_amount, 0))), 0)
      into v_available
    from public.pb_excess_payments ep
    where ep.business_id = v_business_id
      and ep.loan_id = p_loan_id
      and ep.member_id = v_loan.member_id::text
      and ep.source = 'scheduled_prepayment'
      and ep.status = 'pending'
      and ep.payment_date <= v_today;
    if v_available + 0.01 < v_balance then
      return jsonb_build_object('success', false, 'status', 'insufficient',
        'loan_id', p_loan_id, 'balance', v_balance,
        'available_deposit', round(v_available, 2),
        'cash_still_needed', round(v_balance - v_available, 2));
    end if;

    for v_deposit in
      select ep.* from public.pb_excess_payments ep
      where ep.business_id = v_business_id
        and ep.loan_id = p_loan_id
        and ep.member_id = v_loan.member_id::text
        and ep.source = 'scheduled_prepayment'
        and ep.status = 'pending'
        and ep.payment_date <= v_today
        and ep.excess_amount > coalesce(ep.released_amount, 0)
      order by ep.payment_date, ep.created_at, ep.id
      for update
    loop
      exit when v_balance <= 0.01;
      v_use := round(least(v_balance,
        v_deposit.excess_amount - coalesce(v_deposit.released_amount, 0)), 2);
      if v_use <= 0 then continue; end if;

      select r.recorded_by into v_recorded_by
      from public.pb_repayments r
      where r.id::text = v_deposit.original_repayment_id
        and r.business_id::text = v_business_id
      limit 1;
      if v_recorded_by is null then
        raise exception 'The source repayment for a loan deposit could not be verified.';
      end if;
      v_principal := round(v_use * coalesce(v_loan.loan_value, 0)
        / v_loan.total_payable, 2);
      insert into public.pb_repayments (
        business_id, loan_id, member_id, group_id, meeting_date, amount,
        principal, interest, recorded_by, status, notes
      ) values (
        v_loan.business_id, v_loan.id, v_loan.member_id, v_loan.group_id,
        v_today, v_use, v_principal, round(v_use - v_principal, 2),
        v_recorded_by, 'approved',
        'Scheduled prepayment release: early close ' || v_deposit.id::text
      ) returning id::text into v_repayment_id;

      insert into public.pb_early_loan_closure_allocations (
        business_id, loan_id, member_id, prepayment_id, repayment_id,
        amount, closed_by_staff_id
      ) values (
        v_business_id, p_loan_id, v_loan.member_id::text,
        v_deposit.id::text, v_repayment_id, v_use, v_staff_id
      );

      update public.pb_excess_payments ep
      set released_amount = round(coalesce(ep.released_amount, 0) + v_use, 2),
          last_released_at = now(),
          status = case when coalesce(ep.released_amount, 0) + v_use + 0.005
                   >= ep.excess_amount then 'applied_to_loan' else 'pending' end,
          resolution_reference = case when coalesce(ep.released_amount, 0) + v_use + 0.005
                   >= ep.excess_amount then 'Early closure of loan ' || p_loan_id
                   else ep.resolution_reference end,
          resolved_at = case when coalesce(ep.released_amount, 0) + v_use + 0.005
                   >= ep.excess_amount then now() else ep.resolved_at end,
          updated_at = now()
      where ep.id = v_deposit.id;

      v_balance := round(v_balance - v_use, 2);
      v_applied := round(v_applied + v_use, 2);
    end loop;
  end if;

  if v_balance > 0.01 then
    raise exception 'Loan deposits changed while closing. No change was saved.';
  end if;
  update public.pb_loans l set status = 'completed'
  where l.id::text = p_loan_id and l.business_id::text = v_business_id
    and lower(coalesce(l.status::text, '')) = 'active';
  return jsonb_build_object('success', true, 'status', 'completed',
    'loan_id', p_loan_id, 'applied_deposit', v_applied);
end;
$$;

revoke all on function public.pb_close_paid_loan_early(text) from public, anon;
grant execute on function public.pb_close_paid_loan_early(text) to authenticated;

commit;

select 'Early paid-loan closure option installed; existing financial rows unchanged' as result;
