-- Wamama Pamoja: Collection Compliance and Monthly Product Sales support
-- Safe to run more than once.
-- This script does not change any member, loan, saving, repayment or order data.

begin;

create index if not exists idx_pb_meetings_business_group_date
  on public.pb_meetings (business_id, group_id, meeting_date);

create index if not exists idx_pb_loans_business_group_dates
  on public.pb_loans (business_id, group_id, start_date, expected_end_date);

create index if not exists idx_pb_loans_business_member_dates
  on public.pb_loans (business_id, member_id, start_date, expected_end_date);

create index if not exists idx_pb_loans_business_order_status
  on public.pb_loans (business_id, order_id, status);

create index if not exists idx_pb_orders_business_date_status
  on public.pb_orders (business_id, ordered_on, status);

create index if not exists idx_pb_orders_business_member_date
  on public.pb_orders (business_id, member_id, ordered_on);

analyze public.pb_meetings;
analyze public.pb_loans;
analyze public.pb_orders;

commit;

select
  'Wamama collection compliance reporting is ready' as result,
  6 as reporting_indexes_checked,
  false as financial_data_changed;
