-- Wamama Pamoja Enterprise
-- Read-only review of completed loans whose recorded repayment total is below
-- total payable. This script does not change loan statuses, balances, savings,
-- deposits or repayments.

with target_business as (
  select s.business_id::text as business_id
  from public.pb_staff s
  where lower(coalesce(s.email, '')) = 'wamamapamojaent@gmail.com'
  order by case when lower(coalesce(s.status, 'active')) = 'active' then 0 else 1 end
  limit 1
),
repayment_totals as (
  select
    r.loan_id::text as loan_id,
    count(*)::integer as repayment_rows,
    sum(coalesce(r.amount, 0))::numeric as repayment_total,
    max(coalesce(r.meeting_date::timestamptz, r.created_at)) as last_payment_at
  from public.pb_repayments r
  join target_business b on b.business_id = r.business_id::text
  where lower(coalesce(r.status::text, 'approved'))
        not in ('pending', 'rejected', 'cancelled')
  group by r.loan_id::text
),
loan_deposits as (
  select
    ep.loan_id::text as loan_id,
    sum(coalesce(ep.excess_amount, 0))::numeric as deposit_total,
    sum(coalesce(ep.released_amount, 0))::numeric as deposit_released,
    sum(greatest(0, coalesce(ep.excess_amount, 0)-coalesce(ep.released_amount, 0)))::numeric as deposit_available
  from public.pb_excess_payments ep
  join target_business b on b.business_id = ep.business_id::text
  where lower(coalesce(ep.source, '')) = 'scheduled_prepayment'
    and lower(coalesce(ep.status, 'pending')) not in ('refunded','cancelled','rejected','transferred_to_savings')
  group by ep.loan_id::text
),
member_deposits as (
  select
    ep.member_id::text as member_id,
    sum(greatest(0, coalesce(ep.excess_amount, 0)-coalesce(ep.released_amount, 0)))::numeric as member_available_deposit
  from public.pb_excess_payments ep
  join target_business b on b.business_id = ep.business_id::text
  where lower(coalesce(ep.source, '')) = 'scheduled_prepayment'
    and lower(coalesce(ep.status, 'pending')) = 'pending'
  group by ep.member_id::text
)
select
  l.id as loan_id,
  m.full_name as client_name,
  m.phone,
  g.name as group_name,
  l.asset_name,
  l.start_date,
  l.expected_end_date,
  l.updated_at as loan_last_updated_at,
  round(coalesce(l.total_payable, 0)::numeric, 2) as total_payable,
  round(coalesce(rt.repayment_total, 0), 2) as recorded_repayment_total,
  round(greatest(0, coalesce(l.total_payable, 0)-coalesce(rt.repayment_total, 0))::numeric, 2) as recorded_shortfall,
  coalesce(rt.repayment_rows, 0) as repayment_rows,
  rt.last_payment_at,
  round(coalesce(ld.deposit_total, 0), 2) as source_loan_deposit_total,
  round(coalesce(ld.deposit_released, 0), 2) as source_loan_deposit_released,
  round(coalesce(ld.deposit_available, 0), 2) as source_loan_deposit_available,
  round(coalesce(md.member_available_deposit, 0), 2) as all_available_member_deposits,
  case
    when coalesce(rt.repayment_rows, 0)=0 then
      'Historical/imported completion with no repayment rows - verify against the original ledger'
    when greatest(0,coalesce(l.total_payable,0)-coalesce(rt.repayment_total,0))
         <= coalesce(md.member_available_deposit,0)+0.01 then
      'Shortfall is covered by an available loan deposit - review completion date and release schedule'
    else
      'Completed below recorded repayments - review the original ledger before changing status'
  end as review_finding
from public.pb_loans l
join target_business b on b.business_id = l.business_id::text
left join public.pb_members m on m.id::text = l.member_id::text
left join public.pb_groups g on g.id::text = l.group_id::text
left join repayment_totals rt on rt.loan_id = l.id::text
left join loan_deposits ld on ld.loan_id = l.id::text
left join member_deposits md on md.member_id = l.member_id::text
where lower(coalesce(l.status::text, '')) = 'completed'
  and coalesce(rt.repayment_total, 0)+0.01 < coalesce(l.total_payable, 0)
order by recorded_shortfall desc, m.full_name, l.start_date;
