-- Read-only follow-up for completed loans with a recorded repayment shortfall.
-- Returns possible replacement loans, available deposits and closure history.
-- A possible replacement is evidence for review, not permission to cancel/reopen.
with loans as (
  select l.*,to_jsonb(l) as detail from public.pb_loans l
  where l.business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28'
), members as (
  select m.*,to_jsonb(m) as detail from public.pb_members m
  where m.business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28'
), totals as (
  select r.loan_id::text as loan_id,
    round(coalesce(sum(r.amount) filter(where r.voided_at is null
      and lower(coalesce(r.status,'approved')) not in ('pending','rejected','cancelled','voided')
      and coalesce(r.meeting_date::date,(r.created_at at time zone 'Africa/Nairobi')::date)
        <=(now() at time zone 'Africa/Nairobi')::date),0),2) as paid,
    count(*) as all_repayment_rows,
    min(r.created_at) as first_repayment_recorded_at,
    max(r.updated_at) as last_repayment_updated_at
  from public.pb_repayments r
  where r.business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28'
  group by r.loan_id::text
), flagged as (
  select l.*,coalesce(t.paid,0) as valid_paid,
    round(l.total_payable::numeric-coalesce(t.paid,0),2) as remaining_balance,
    coalesce(t.all_repayment_rows,0) as all_repayment_rows,
    t.first_repayment_recorded_at,t.last_repayment_updated_at
  from loans l left join totals t on t.loan_id=l.id::text
  where l.status='completed' and coalesce(l.total_payable,0)-coalesce(t.paid,0)>0.01
), counterpart_rows as (
  select f.id::text as flagged_id,a.id as other_id,a.asset_name,a.status,a.start_date,
    a.loan_value,a.total_payable,a.weekly_installment,coalesce(t.paid,0) as valid_paid,
    round(greatest(0,a.total_payable::numeric-coalesce(t.paid,0)),2) as remaining_balance,
    (a.member_id::text=f.member_id::text) as same_member_record
  from flagged f
  join members fm on fm.id::text=f.member_id::text
  join loans a on a.id::text<>f.id::text and a.status in ('active','completed','defaulted')
  join members am on am.id::text=a.member_id::text
  left join totals t on t.loan_id=a.id::text
  where (a.member_id::text=f.member_id::text
    or (nullif(trim(fm.detail->>'national_id'),'') is not null
      and trim(fm.detail->>'national_id')=trim(am.detail->>'national_id'))
    or (length(regexp_replace(coalesce(fm.detail->>'phone',''),'[^0-9]','','g'))>=9
      and regexp_replace(fm.detail->>'phone','[^0-9]','','g')=regexp_replace(am.detail->>'phone','[^0-9]','','g')))
    and abs(coalesce(a.loan_value,0)-coalesce(f.loan_value,0))<0.01
    and (nullif(trim(f.asset_name),'') is not null
      and lower(regexp_replace(trim(a.asset_name),'[[:space:]]+',' ','g'))
        =lower(regexp_replace(trim(f.asset_name),'[[:space:]]+',' ','g')))
), counterparts as (
  select flagged_id,count(*) as possible_replacements,
    jsonb_agg(jsonb_build_object('loan_id',other_id,'same_member_record',same_member_record,
      'asset',asset_name,'status',status,'start_date',start_date,'loan_value',loan_value,
      'weekly_installment',weekly_installment,'total_payable',total_payable,
      'valid_paid',valid_paid,'remaining_balance',remaining_balance) order by start_date,other_id) as other_loans
  from counterpart_rows group by flagged_id
), deposits as (
  select ep.loan_id::text as loan_id,
    round(sum(greatest(0,coalesce(ep.excess_amount,0)-coalesce(ep.released_amount,0))),2) as available
  from public.pb_excess_payments ep
  where ep.business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28'
    and ep.source='scheduled_prepayment' and ep.status='pending'
  group by ep.loan_id::text
), latest_events as (
  select a.*,row_number() over(partition by a.entity_id::text order by a.created_at desc,a.id::text desc) as event_number
  from public.pb_audit_log a join flagged f on f.id::text=a.entity_id::text
  where a.business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28'
), events as (
  select entity_id::text as loan_id,
    jsonb_agg(jsonb_build_object('at',created_at,'staff',staff_name,'action',action,
      'old_status',old_value->>'status','new_status',new_value->>'status',
      'old_total_payable',old_value->>'total_payable','new_total_payable',new_value->>'total_payable',
      'reason',coalesce(new_value->>'reason',new_value->>'notes'),
      'kept_loan_id',coalesce(new_value->>'keep_loan_id',new_value->>'kept_loan_id')) order by created_at desc) as loan_events
  from latest_events where event_number<=5 group by entity_id::text
)
select coalesce(s.full_name,'Unassigned') as current_officer,m.full_name as member,
  f.id as loan_id,f.asset_name,f.start_date,f.detail->>'created_at' as loan_created_at,
  f.detail->>'updated_at' as loan_updated_at,f.detail->>'order_id' as order_id,
  f.loan_value,f.total_payable,f.valid_paid,f.remaining_balance,f.all_repayment_rows,
  f.first_repayment_recorded_at,f.last_repayment_updated_at,
  coalesce(d.available,0) as available_deposit_on_this_loan,
  coalesce(c.possible_replacements,0) as possible_replacements,
  coalesce(c.other_loans,'[]'::jsonb) as possible_replacement_details,
  coalesce(e.loan_events,'[]'::jsonb) as latest_loan_actions,
  case when coalesce(c.possible_replacements,0)>0 then 'Review possible replacement; do not reopen automatically'
    when coalesce(d.available,0)+0.01>=f.remaining_balance then 'Review deposit and closure history; deposit is not a recorded repayment'
    when f.all_repayment_rows=0 then 'No repayment rows; original ledger or import history is required'
    else 'Review recorded payments and completion history against the original ledger'
  end as next_check
from flagged f
left join members m on m.id::text=f.member_id::text
left join public.pb_groups g on g.id::text=coalesce(m.group_id::text,f.group_id::text) and g.business_id::text=f.business_id::text
left join public.pb_staff s on s.id::text=(case when g.id is null then f.officer_id::text else g.officer_id::text end)
  and s.business_id::text=f.business_id::text
left join counterparts c on c.flagged_id=f.id::text
left join deposits d on d.loan_id=f.id::text
left join events e on e.loan_id=f.id::text
order by current_officer,f.remaining_balance desc,f.id;
