-- Read-only check, run after wamama-authoritative-financial-snapshot.sql.
-- All officers are measured on the same Kenya date, with current assignments.
-- Historical loan status problems are reported, never silently changed.
with repayment_totals as (
  select r.loan_id::text as loan_id,
    round(sum(r.amount) filter(where r.voided_at is null and lower(coalesce(r.status,'approved')) not in ('pending','rejected','cancelled','voided')
      and coalesce(r.meeting_date::date,(r.created_at at time zone 'Africa/Nairobi')::date)<=(now() at time zone 'Africa/Nairobi')::date),2) as paid
  from public.pb_repayments r where r.business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28'
  group by r.loan_id::text
), ledger as (
  select l.*,coalesce(p.paid,0) as paid,
    (case when g.id is null then l.officer_id::text else g.officer_id::text end) as current_officer_id,
    round(greatest(0,coalesce(l.total_payable,0)-coalesce(p.paid,0)),2) as balance,
    round(greatest(0,(case when l.start_date is null or l.start_date::date>=(now() at time zone 'Africa/Nairobi')::date then 0 else
      least(coalesce(l.total_payable,0),ceil(((now() at time zone 'Africa/Nairobi')::date-l.start_date::date)/7.0)*coalesce(l.weekly_installment,0)) end)-coalesce(p.paid,0)-5),2) as arrears
  from public.pb_loans l left join repayment_totals p on p.loan_id=l.id::text
  left join public.pb_members m on m.id::text=l.member_id::text and m.business_id::text=l.business_id::text
  left join public.pb_groups g on g.id::text=coalesce(m.group_id::text,l.group_id::text) and g.business_id::text=l.business_id::text
  where l.business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28'
)
select
  (now() at time zone 'Africa/Nairobi')::date as kenya_report_date,
  coalesce(s.full_name,'Unassigned') as officer,
  to_regprocedure('public.pb_financial_snapshot(text[],timestamp with time zone)') is not null as snapshot_ready,
  to_regprocedure('public.pb_cash_collection_totals(date,date)') is not null as cash_totals_ready,
  count(*) filter(where l.status='active') as active_loans,
  coalesce(sum(l.balance) filter(where l.status='active'),0) as outstanding_including_interest,
  count(*) filter(where l.status='active' and l.arrears>0) as loans_in_arrears,
  coalesce(sum(l.arrears) filter(where l.status='active'),0) as arrears_amount,
  count(*) filter(where l.status='completed' and l.balance>0.01) as completed_but_underpaid_review,
  count(*) filter(where l.status='active' and l.total_payable>0 and l.paid+0.01>=l.total_payable) as fully_paid_but_active_review,
  count(*) filter(where l.status='active' and (l.start_date is null or coalesce(l.weekly_installment,0)<=0)) as invalid_schedule_review
from ledger l left join public.pb_staff s on s.id::text=l.current_officer_id and s.business_id::text=l.business_id::text
group by s.id,s.full_name order by officer;
