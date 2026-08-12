-- Wamama Pamoja Enterprise
-- PREVIEW ONLY: identify historical loan deposits / prepayments that were moved into savings.
-- This does not change any data.

with transferred as (
  select
    ep.id as loan_deposit_id,
    ep.business_id,
    ep.member_id,
    ep.group_id,
    ep.loan_id,
    ep.original_repayment_id,
    ep.payment_date,
    ep.excess_amount,
    ep.status,
    m.full_name,
    m.phone,
    g.name as group_name,
    l.asset_name,
    s.id as linked_savings_id,
    s.amount as linked_savings_amount,
    s.meeting_date as linked_savings_date,
    s.notes as linked_savings_notes
  from public.pb_excess_payments ep
  left join public.pb_members m on m.id::text = ep.member_id::text
  left join public.pb_groups g on g.id::text = ep.group_id::text
  left join public.pb_loans l on l.id::text = ep.loan_id::text
  left join public.pb_savings s
    on s.member_id::text = ep.member_id::text
   and s.business_id::text = ep.business_id::text
   and s.amount = ep.excess_amount
   and lower(coalesce(s.status, 'approved')) = 'approved'
   and (
     s.notes = 'Loan overpayment transferred to savings; repayment ' || ep.original_repayment_id::text
     or s.notes = 'Historical loan overpayment transferred to savings; excess record ' || ep.id::text
     or s.notes ilike '%loan overpayment transferred to savings%'
   )
  where ep.status = 'transferred_to_savings'
)
select
  'SUMMARY - preview only, no data changed' as section,
  count(*) as transferred_records,
  coalesce(sum(excess_amount), 0) as transferred_amount,
  count(linked_savings_id) as linked_savings_rows_found,
  coalesce(sum(linked_savings_amount), 0) as linked_savings_amount_found
from transferred

union all

select
  'DETAIL - review affected clients before applying' as section,
  null::bigint as transferred_records,
  null::numeric as transferred_amount,
  null::bigint as linked_savings_rows_found,
  null::numeric as linked_savings_amount_found
limit 2;

select
  full_name,
  phone,
  group_name,
  asset_name,
  payment_date,
  excess_amount as amount_to_restore_as_loan_deposit,
  linked_savings_amount,
  case
    when linked_savings_id is null then 'No linked savings row found - review manually'
    else 'Can reverse linked savings row and restore loan deposit'
  end as recommended_action
from transferred
order by payment_date desc, full_name
limit 200;
