-- Read-only: identify completed loans whose remaining balance needs review.
-- No loans are reopened and no repayments are changed.
with totals as (
  select r.loan_id::text as loan_id,
    round(coalesce(sum(r.amount) filter (where r.voided_at is null
      and lower(coalesce(r.status,'approved')) not in ('pending','rejected','cancelled','voided')
      and coalesce(r.meeting_date::date,(r.created_at at time zone 'Africa/Nairobi')::date)
        <= (now() at time zone 'Africa/Nairobi')::date),0),2) as valid_paid,
    round(coalesce(sum(r.amount) filter (where r.voided_at is not null
      and lower(coalesce(r.status,'approved'))='approved'),0),2) as voided_approved_amount,
    round(coalesce(sum(r.amount) filter (where r.voided_at is null
      and lower(coalesce(r.status,'approved')) not in ('pending','rejected','cancelled','voided')
      and coalesce(r.meeting_date::date,(r.created_at at time zone 'Africa/Nairobi')::date)
        > (now() at time zone 'Africa/Nairobi')::date),0),2) as future_dated_amount,
    count(*) filter (where r.voided_at is not null) as voided_rows
  from public.pb_repayments r
  where r.business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28'
  group by r.loan_id::text
)
select coalesce(s.full_name,'Unassigned') as current_officer,
  m.full_name as member, l.id as loan_id, l.asset_name, l.start_date,
  l.status, round(l.total_payable::numeric,2) as total_payable,
  coalesce(t.valid_paid,0) as valid_paid,
  round(l.total_payable::numeric-coalesce(t.valid_paid,0),2) as remaining_balance,
  coalesce(t.voided_approved_amount,0) as voided_approved_amount,
  coalesce(t.voided_rows,0) as voided_rows,
  coalesce(t.future_dated_amount,0) as future_dated_amount,
  case when coalesce(t.valid_paid,0)+coalesce(t.voided_approved_amount,0)+0.01>=l.total_payable
    then 'Voided repayments could explain the completed status; review before reopening'
    when coalesce(t.valid_paid,0)+coalesce(t.future_dated_amount,0)+0.01>=l.total_payable
    then 'Future-dated repayments could explain the completed status; review payment dates'
    else 'Review completion or loan correction history before changing status'
  end as review_reason
from public.pb_loans l
left join totals t on t.loan_id=l.id::text
left join public.pb_members m on m.id::text=l.member_id::text and m.business_id::text=l.business_id::text
left join public.pb_groups g on g.id::text=coalesce(m.group_id::text,l.group_id::text) and g.business_id::text=l.business_id::text
left join public.pb_staff s on s.id::text=(case when g.id is null then l.officer_id::text else g.officer_id::text end)
  and s.business_id::text=l.business_id::text
where l.business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28'
  and l.status='completed' and coalesce(l.total_payable,0)-coalesce(t.valid_paid,0)>0.01
order by current_officer, remaining_balance desc, l.id;
