-- Wamama Pamoja Enterprise
-- One-time cleanup: close active loan accounts that are already fully repaid.
-- This excludes pending, rejected, and cancelled repayment entries.

create table if not exists public.pb_fully_paid_loan_close_backup_20260730 as
with approved_repayments as (
  select
    r.loan_id::text as loan_id_text,
    sum(coalesce(r.amount, 0)) as total_paid
  from public.pb_repayments r
  where coalesce(lower(r.status::text), 'approved') not in ('pending', 'rejected', 'cancelled')
  group by r.loan_id::text
),
affected as (
  select
    l.*,
    coalesce(ar.total_paid, 0) as approved_total_paid
  from public.pb_loans l
  left join approved_repayments ar on ar.loan_id_text = l.id::text
  where l.status = 'active'
    and coalesce(ar.total_paid, 0) >= coalesce(l.total_payable, 0)
)
select *
from affected;

with approved_repayments as (
  select
    r.loan_id::text as loan_id_text,
    sum(coalesce(r.amount, 0)) as total_paid
  from public.pb_repayments r
  where coalesce(lower(r.status::text), 'approved') not in ('pending', 'rejected', 'cancelled')
  group by r.loan_id::text
),
affected as (
  select l.id::text as loan_id_text
  from public.pb_loans l
  left join approved_repayments ar on ar.loan_id_text = l.id::text
  where l.status = 'active'
    and coalesce(ar.total_paid, 0) >= coalesce(l.total_payable, 0)
)
update public.pb_loans l
set status = 'completed'
from affected a
where l.id::text = a.loan_id_text;

select
  count(*) as active_fully_paid_loans_remaining
from public.pb_loans l
left join (
  select
    r.loan_id::text as loan_id_text,
    sum(coalesce(r.amount, 0)) as total_paid
  from public.pb_repayments r
  where coalesce(lower(r.status::text), 'approved') not in ('pending', 'rejected', 'cancelled')
  group by r.loan_id::text
) ar on ar.loan_id_text = l.id::text
where l.status = 'active'
  and coalesce(ar.total_paid, 0) >= coalesce(l.total_payable, 0);
