-- Wamama Pamoja Enterprise
-- Pre-loan deposits reduce the financed principal before charges and instalments.
-- Existing loans, repayments, savings and historical balances are not rewritten.

begin;

alter table public.pb_loans
  add column if not exists gross_loan_value numeric(14,2),
  add column if not exists deposit_applied numeric(14,2) not null default 0,
  add column if not exists agreed_term_weeks integer;

create table if not exists public.pb_preloan_deposit_applications (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  deposit_id uuid not null,
  loan_id text not null,
  member_id text not null,
  amount numeric(14,2) not null check (amount > 0),
  applied_by text,
  applied_at timestamptz not null default now(),
  unique (deposit_id, loan_id)
);

create index if not exists pb_preloan_deposit_applications_business_loan_idx
  on public.pb_preloan_deposit_applications (business_id, loan_id, applied_at desc);

create index if not exists pb_preloan_deposit_applications_member_idx
  on public.pb_preloan_deposit_applications (business_id, member_id, applied_at desc);

alter table public.pb_preloan_deposit_applications enable row level security;

drop policy if exists pb_preloan_deposit_applications_select on public.pb_preloan_deposit_applications;
create policy pb_preloan_deposit_applications_select
on public.pb_preloan_deposit_applications
for select to authenticated
using (business_id = public.pb_current_business_id_text());

-- The old trigger converted a pre-loan deposit into future repayments after
-- funding. New loans use the deposit to reduce the financed principal instead.
drop trigger if exists pb_attach_preloan_deposits_trigger on public.pb_loans;

create or replace function public.pb_apply_preloan_deposit_to_loan(
  p_member_id text,
  p_loan_id text,
  p_amount numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.pb_staff%rowtype;
  v_loan public.pb_loans%rowtype;
  v_deposit public.pb_excess_payments%rowtype;
  v_requested numeric(14,2) := round(coalesce(p_amount,0),2);
  v_existing numeric(14,2) := 0;
  v_available numeric(14,2);
  v_use numeric(14,2);
  v_applied numeric(14,2) := 0;
begin
  if v_requested <= 0 then
    return jsonb_build_object('loan_id',p_loan_id,'applied_amount',0);
  end if;

  select s.* into v_staff
  from public.pb_staff s
  where s.auth_user_id = auth.uid()
    and lower(coalesce(s.status,'active')) = 'active'
  limit 1;
  if not found then raise exception 'Your Wamama staff session was not found.'; end if;

  select l.* into v_loan
  from public.pb_loans l
  where l.id::text = p_loan_id
    and l.member_id::text = p_member_id
    and l.business_id::text = v_staff.business_id::text
  for update;
  if not found then raise exception 'The new loan or its client could not be verified.'; end if;

  select coalesce(sum(a.amount),0) into v_existing
  from public.pb_preloan_deposit_applications a
  where a.business_id = v_staff.business_id::text
    and a.loan_id = p_loan_id;
  if abs(v_existing-v_requested) <= 0.005 then
    return jsonb_build_object('loan_id',p_loan_id,'applied_amount',v_existing,'already_applied',true);
  elsif v_existing > 0 then
    raise exception 'A different deposit amount is already attached to this loan.';
  end if;

  for v_deposit in
    select ep.*
    from public.pb_excess_payments ep
    where ep.business_id = v_staff.business_id::text
      and ep.member_id = p_member_id
      and ep.status = 'pending'
      and ep.source = 'pre_loan_deposit'
      and ep.loan_id is null
      and ep.excess_amount > coalesce(ep.released_amount,0)
    order by ep.payment_date, ep.created_at, ep.id
    for update
  loop
    exit when v_applied + 0.005 >= v_requested;
    v_available := round(v_deposit.excess_amount-coalesce(v_deposit.released_amount,0),2);
    v_use := least(v_available,round(v_requested-v_applied,2));
    if v_use <= 0 then continue; end if;

    insert into public.pb_preloan_deposit_applications(
      business_id,deposit_id,loan_id,member_id,amount,applied_by
    ) values (
      v_staff.business_id::text,v_deposit.id,p_loan_id,p_member_id,v_use,v_staff.id::text
    );

    update public.pb_excess_payments ep
    set released_amount = round(coalesce(ep.released_amount,0)+v_use,2),
        amount_applied_to_loan = round(coalesce(ep.amount_applied_to_loan,0)+v_use,2),
        loan_id = case
          when round(coalesce(ep.released_amount,0)+v_use,2)+0.005 >= ep.excess_amount
            then p_loan_id else ep.loan_id end,
        status = case
          when round(coalesce(ep.released_amount,0)+v_use,2)+0.005 >= ep.excess_amount
            then 'applied_to_loan' else 'pending' end,
        resolution_reference = case
          when round(coalesce(ep.released_amount,0)+v_use,2)+0.005 >= ep.excess_amount
            then 'Applied before funding to loan '||p_loan_id else ep.resolution_reference end,
        resolved_at = case
          when round(coalesce(ep.released_amount,0)+v_use,2)+0.005 >= ep.excess_amount
            then now() else ep.resolved_at end,
        resolved_by = case
          when round(coalesce(ep.released_amount,0)+v_use,2)+0.005 >= ep.excess_amount
            then v_staff.id::text else ep.resolved_by end,
        notes = concat_ws(' | ',nullif(ep.notes,''),
          format('KES %s deducted before financing loan %s',trim(to_char(v_use,'FM9999999990.00')),p_loan_id)),
        updated_at = now()
    where ep.id = v_deposit.id;

    v_applied := round(v_applied+v_use,2);
  end loop;

  if abs(v_applied-v_requested) > 0.005 then
    raise exception 'Available pre-loan deposit is KES %, but KES % was requested.',
      trim(to_char(v_applied,'FM9999999990.00')),trim(to_char(v_requested,'FM9999999990.00'));
  end if;

  return jsonb_build_object(
    'loan_id',p_loan_id,
    'member_id',p_member_id,
    'applied_amount',v_applied,
    'gross_loan_value',v_loan.gross_loan_value,
    'financed_amount',v_loan.loan_value
  );
end;
$$;

grant execute on function public.pb_apply_preloan_deposit_to_loan(text,text,numeric) to authenticated;
revoke all on function public.pb_apply_preloan_deposit_to_loan(text,text,numeric) from public, anon;

commit;

-- Diagnostic report: identifies the screenshot client and every pending order
-- whose client currently has an unapplied pre-loan deposit. No data changes here.
with member_deposits as (
  select
    m.id,
    m.business_id,
    m.full_name,
    m.phone,
    m.group_id,
    round(coalesce(sum(
      case when ep.status='pending' and ep.source='pre_loan_deposit' and ep.loan_id is null
        then greatest(0,ep.excess_amount-coalesce(ep.released_amount,0)) else 0 end
    ),0),2) as available_preloan_deposit
  from public.pb_members m
  left join public.pb_excess_payments ep
    on ep.business_id=m.business_id::text and ep.member_id=m.id::text
  group by m.id,m.business_id,m.full_name,m.phone,m.group_id
), pending_orders as (
  select
    md.*,
    g.name as group_name,
    o.id as order_id,
    o.asset_name,
    o.desired_weeks,
    o.desired_weekly_installment,
    o.ordered_on
  from member_deposits md
  left join public.pb_groups g on g.id::text=md.group_id::text
  left join public.pb_orders o
    on o.member_id::text=md.id::text and lower(coalesce(o.status,''))='pending'
  where lower(md.full_name) like '%agnes%nzilani%'
     or md.available_preloan_deposit > 0
)
select
  case when lower(full_name) like '%agnes%nzilani%' then 1 else 2 end as section_order,
  case when lower(full_name) like '%agnes%nzilani%'
    then 'Screenshot client check' else 'Other clients with unapplied pre-loan deposits' end as section,
  jsonb_build_object(
    'member_id',id,
    'client_name',full_name,
    'phone',phone,
    'group_name',group_name,
    'available_preloan_deposit',available_preloan_deposit,
    'pending_order_id',order_id,
    'product',asset_name,
    'desired_weeks',desired_weeks,
    'old_desired_weekly',desired_weekly_installment,
    'ordered_on',ordered_on,
    'next_action',case
      when available_preloan_deposit>0 and order_id is not null then 'Approve after deploying the updated index file'
      when available_preloan_deposit=0 then 'Confirm whether the client deposit was recorded under Record Loan Deposit'
      else 'Deposit exists but no pending order is linked to this client' end
  ) as result
from pending_orders
order by section_order,full_name,ordered_on;
