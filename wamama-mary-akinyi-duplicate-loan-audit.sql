-- READ-ONLY: trace Mary Akinyi Auka's duplicate loans and every payment link.
-- Run the whole file in Supabase SQL Editor and send back the single result.

with target_members as (
  select m.*
  from public.pb_members m
  where lower(coalesce(m.full_name,'')) like '%mary%akinyi%auka%'
     or regexp_replace(coalesce(m.phone,''),'[^0-9]','','g') like '%0707156588%'
), target_loans as (
  select l.*
  from public.pb_loans l
  join target_members m on m.id::text=l.member_id::text
), audit_rows as (
  select
    1 as sort_group,
    coalesce(l.start_date,l.created_at::date) as sort_date,
    'LOAN'::text as record_type,
    l.id::text as record_id,
    l.id::text as loan_id,
    jsonb_build_object(
      'member_name',m.full_name,
      'phone',m.phone,
      'status',l.status,
      'start_date',l.start_date,
      'asset_name',l.asset_name,
      'loan_value',l.loan_value,
      'total_payable',l.total_payable,
      'weekly_installment',l.weekly_installment,
      'order_id',l.order_id,
      'created_at',l.created_at
    ) as details
  from target_loans l
  join target_members m on m.id::text=l.member_id::text

  union all

  select
    2,
    coalesce(r.meeting_date,r.created_at::date),
    'REPAYMENT',
    r.id::text,
    r.loan_id::text,
    to_jsonb(r)
  from public.pb_repayments r
  join target_loans l on l.id::text=r.loan_id::text

  union all

  select
    3,
    coalesce(ep.payment_date,ep.created_at::date),
    'PREPAYMENT_OR_EXCESS',
    ep.id::text,
    ep.loan_id::text,
    to_jsonb(ep)
  from public.pb_excess_payments ep
  join target_loans l on l.id::text=ep.loan_id::text

  union all

  select
    4,
    pr.due_date,
    'PREPAYMENT_RELEASE',
    pr.id::text,
    pr.loan_id::text,
    to_jsonb(pr)
  from public.pb_prepayment_releases pr
  join target_loans l on l.id::text=pr.loan_id::text
)
select record_type,record_id,loan_id,sort_date as activity_date,details
from audit_rows
order by loan_id,sort_group,sort_date,record_id;
