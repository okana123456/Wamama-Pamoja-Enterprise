-- READ-ONLY preview. This file does not insert, update or delete anything.
-- Run it before the Excess Payments setup to review the exact historical impact.

with repayment_totals as (
  select
    r.loan_id::text as loan_id,
    round(coalesce(sum(r.amount), 0), 2) as repayment_total
  from public.pb_repayments r
  where lower(coalesce(r.status, 'approved')) not in ('pending','rejected','cancelled')
  group by r.loan_id::text
), affected as (
  select
    l.id::text as loan_id,
    l.business_id::text as business_id,
    m.full_name as member_name,
    m.phone as member_phone,
    g.name as group_name,
    l.asset_name,
    round(l.total_payable, 2) as total_payable,
    rt.repayment_total,
    round(rt.repayment_total - l.total_payable, 2) as excess_to_separate,
    l.status as loan_status
  from public.pb_loans l
  join repayment_totals rt on rt.loan_id = l.id::text
  left join public.pb_members m on m.id::text = l.member_id::text
  left join public.pb_groups g on g.id::text = l.group_id::text
  where coalesce(l.total_payable, 0) > 0
    and rt.repayment_total > l.total_payable
)
select
  1 as section_order,
  'Summary - no data changed' as section,
  jsonb_build_object(
    'affected_loans', count(*),
    'total_excess_to_separate', round(coalesce(sum(excess_to_separate), 0), 2)
  ) as result
from affected

union all

select
  2 as section_order,
  'Affected loans - no data changed' as section,
  coalesce(jsonb_agg(to_jsonb(affected) order by excess_to_separate desc), '[]'::jsonb) as result
from affected
order by section_order;

