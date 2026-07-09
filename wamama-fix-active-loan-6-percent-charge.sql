-- Wamama Pamoja Enterprise
-- Fix active loans whose total_payable is below principal + 6% service charge.
-- Run this once after reviewing the diagnostic result.

begin;

create table if not exists public.pb_loan_6pct_fix_backup_20260709 (
  backup_id bigserial primary key,
  backed_up_at timestamptz not null default now(),
  loan_id text not null,
  business_id text,
  member_id text,
  old_total_payable numeric,
  new_total_payable numeric,
  old_weekly_installment numeric,
  old_expected_end_date date,
  new_expected_end_date date,
  missing_amount numeric
);

with affected as (
  select
    l.id as loan_id,
    l.business_id,
    l.member_id,
    coalesce(l.total_payable, 0)::numeric as old_total_payable,
    round((coalesce(l.loan_value, 0)::numeric * 1.06), 2) as new_total_payable,
    coalesce(l.weekly_installment, 0)::numeric as old_weekly_installment,
    l.expected_end_date as old_expected_end_date,
    case
      when coalesce(l.weekly_installment, 0) > 0 and l.start_date is not null then
        (l.start_date::date + (ceil(round((coalesce(l.loan_value, 0)::numeric * 1.06), 2) / coalesce(l.weekly_installment, 0)::numeric)::int * 7))
      else l.expected_end_date
    end as new_expected_end_date,
    round((coalesce(l.loan_value, 0)::numeric * 1.06) - coalesce(l.total_payable, 0)::numeric, 2) as missing_amount
  from public.pb_loans l
  where l.status = 'active'
    and coalesce(l.loan_value, 0) > 0
    and coalesce(l.total_payable, 0) < round((coalesce(l.loan_value, 0)::numeric * 1.06), 2)
)
insert into public.pb_loan_6pct_fix_backup_20260709 (
  loan_id,
  business_id,
  member_id,
  old_total_payable,
  new_total_payable,
  old_weekly_installment,
  old_expected_end_date,
  new_expected_end_date,
  missing_amount
)
select
  a.loan_id::text,
  a.business_id::text,
  a.member_id::text,
  a.old_total_payable,
  a.new_total_payable,
  a.old_weekly_installment,
  a.old_expected_end_date,
  a.new_expected_end_date,
  a.missing_amount
from affected a
where not exists (
  select 1
  from public.pb_loan_6pct_fix_backup_20260709 b
  where b.loan_id = a.loan_id
);

with affected as (
  select
    l.id as loan_id,
    round((coalesce(l.loan_value, 0)::numeric * 1.06), 2) as new_total_payable,
    case
      when coalesce(l.weekly_installment, 0) > 0 and l.start_date is not null then
        (l.start_date::date + (ceil(round((coalesce(l.loan_value, 0)::numeric * 1.06), 2) / coalesce(l.weekly_installment, 0)::numeric)::int * 7))
      else l.expected_end_date
    end as new_expected_end_date
  from public.pb_loans l
  where l.status = 'active'
    and coalesce(l.loan_value, 0) > 0
    and coalesce(l.total_payable, 0) < round((coalesce(l.loan_value, 0)::numeric * 1.06), 2)
)
update public.pb_loans l
set
  total_payable = a.new_total_payable,
  expected_end_date = a.new_expected_end_date
from affected a
where l.id = a.loan_id;

commit;

-- Confirm what was fixed.
select
  count(*) as loans_fixed,
  sum(missing_amount) as total_amount_added_to_active_loans
from public.pb_loan_6pct_fix_backup_20260709
where backed_up_at >= now() - interval '10 minutes';

-- Confirm no active loans remain below principal + 6%.
select
  count(*) as active_loans_still_missing_6_percent
from public.pb_loans
where status = 'active'
  and coalesce(loan_value, 0) > 0
  and coalesce(total_payable, 0) < round((coalesce(loan_value, 0)::numeric * 1.06), 2);
