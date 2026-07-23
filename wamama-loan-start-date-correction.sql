-- Wamama loan start-date correction helper.
-- Use Section 1 to find loans whose repayment start date looks earlier than creation.
-- Use Section 2 only after replacing the loan id and correct date.

-- Section 1: check suspicious loan dates
select
  l.id as loan_id,
  m.full_name as member_name,
  g.name as group_name,
  l.asset_name,
  l.status,
  l.loan_value,
  l.weekly_installment,
  l.total_payable,
  l.start_date,
  l.expected_end_date,
  l.created_at
from public.pb_loans l
left join public.pb_members m on m.id = l.member_id
left join public.pb_groups g on g.id = l.group_id
where l.status in ('active','pending')
  and l.start_date is not null
  and l.created_at is not null
  and l.start_date < (l.created_at::date - interval '1 day')
order by l.created_at desc, l.start_date asc;

-- Section 2: correct one loan after confirming the loan_id above.
-- Replace the values below, then remove the leading -- from the update block.
--
-- update public.pb_loans
-- set
--   start_date = date '2026-07-28',
--   expected_end_date = date '2026-07-28' + ((ceil(total_payable / nullif(weekly_installment, 0))::int) * interval '7 days')
-- where id = 'PASTE_LOAN_ID_HERE';
--
-- select id, start_date, expected_end_date, weekly_installment, total_payable
-- from public.pb_loans
-- where id = 'PASTE_LOAN_ID_HERE';
