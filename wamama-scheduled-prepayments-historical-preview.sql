-- Wamama Pamoja Enterprise
-- READ-ONLY preview of older pending loan-deposit records.
-- This file changes no savings, repayments, loans or balances.
-- Run it only after wamama-scheduled-loan-prepayments.sql.

with kenya_clock as (
  select (now() at time zone 'Africa/Nairobi')::date as today
), historical as (
  select
    ep.id,
    ep.business_id,
    ep.member_id,
    ep.loan_id,
    ep.payment_date,
    ep.original_payment_amount,
    ep.amount_applied_to_loan,
    ep.excess_amount,
    coalesce(ep.released_amount, 0) as released_amount,
    ep.source,
    l.status as loan_status,
    l.start_date,
    l.expected_end_date,
    l.weekly_installment,
    l.total_payable,
    m.full_name,
    m.phone,
    g.name as group_name
  from public.pb_excess_payments ep
  left join public.pb_loans l on l.id::text = ep.loan_id
  left join public.pb_members m on m.id::text = ep.member_id
  left join public.pb_groups g on g.id::text = ep.group_id
  where ep.status = 'pending'
    and coalesce(ep.source, '') <> 'scheduled_prepayment'
), paid as (
  select
    r.loan_id::text as loan_id,
    coalesce(sum(r.amount), 0) as approved_repayments
  from public.pb_repayments r
  where lower(coalesce(r.status, 'approved')) not in ('pending','rejected','cancelled')
  group by r.loan_id::text
)
select
  h.id as deposit_id,
  h.full_name,
  h.phone,
  h.group_name,
  h.payment_date,
  h.loan_status,
  h.start_date,
  h.expected_end_date,
  h.weekly_installment,
  h.total_payable,
  coalesce(p.approved_repayments, 0) as approved_repayments_now,
  h.excess_amount as historical_deposit_amount,
  case
    when h.loan_id is null then 'Do not migrate - loan link missing'
    when h.full_name is null then 'Do not migrate - member link missing'
    when lower(coalesce(h.loan_status::text, '')) <> 'active' then 'Review - loan is no longer active'
    when h.payment_date is null or h.start_date is null then 'Review - schedule date missing'
    when h.payment_date > h.expected_end_date then 'Review - payment is after scheduled end date'
    else 'Eligible for manual migration after Wamama confirms'
  end as recommendation
from historical h
left join paid p on p.loan_id = h.loan_id
cross join kenya_clock k
order by h.payment_date, h.full_name, h.id;

