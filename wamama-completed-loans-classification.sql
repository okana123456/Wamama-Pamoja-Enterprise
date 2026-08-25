-- Wamama Pamoja Enterprise
-- Final read-only classification of historical completed/underpaid loans.
-- This distinguishes possible old duplicate records from standalone loans.
-- No financial or operational data is changed.

with target_business as (
  select s.business_id::text as business_id
  from public.pb_staff s
  where lower(coalesce(s.email, ''))='wamamapamojaent@gmail.com'
  order by case when lower(coalesce(s.status,'active'))='active' then 0 else 1 end
  limit 1
),
repayment_totals as (
  select r.loan_id::text as loan_id,
         count(*)::integer as repayment_rows,
         sum(coalesce(r.amount,0))::numeric as repayment_total
  from public.pb_repayments r
  join target_business b on b.business_id=r.business_id::text
  where lower(coalesce(r.status::text,'approved')) not in ('pending','rejected','cancelled')
  group by r.loan_id::text
),
flagged as (
  select l.*,
         coalesce(rt.repayment_rows,0) as repayment_rows,
         coalesce(rt.repayment_total,0)::numeric as repayment_total,
         greatest(0,coalesce(l.total_payable,0)-coalesce(rt.repayment_total,0))::numeric as shortfall
  from public.pb_loans l
  join target_business b on b.business_id=l.business_id::text
  left join repayment_totals rt on rt.loan_id=l.id::text
  where lower(coalesce(l.status::text,''))='completed'
    and coalesce(rt.repayment_total,0)+0.01<coalesce(l.total_payable,0)
)
select
  f.id as completed_loan_id,
  m.full_name as client_name,
  m.phone,
  g.name as group_name,
  f.asset_name,
  f.start_date,
  f.expected_end_date,
  round(coalesce(f.total_payable,0)::numeric,2) as total_payable,
  round(f.repayment_total,2) as repayment_total,
  round(f.shortfall,2) as apparent_shortfall,
  f.repayment_rows,
  coalesce(active_matches.active_loan_count,0) as active_loans_for_same_member,
  coalesce(exact_matches.exact_active_counterpart_count,0) as exact_active_counterparts,
  exact_matches.active_counterparts,
  recent_audit.latest_actions,
  case
    when coalesce(exact_matches.exact_active_counterpart_count,0)>0 then
      'Likely historical duplicate/placeholder: an equivalent active loan exists. Do not reopen.'
    when coalesce(active_matches.active_loan_count,0)>0 and f.repayment_rows=0 then
      'Historical completed row with another active loan for this member. Review the original ledger before any change.'
    when f.repayment_rows=0 then
      'Standalone historical completion without repayment rows. Wamama must confirm from the original ledger.'
    else
      'Standalone partial-payment completion. Wamama must confirm whether it was settled outside the recorded repayment ledger.'
  end as classification
from flagged f
left join public.pb_members m on m.id::text=f.member_id::text
left join public.pb_groups g on g.id::text=f.group_id::text
left join lateral (
  select count(*)::integer as active_loan_count
  from public.pb_loans a
  where a.business_id::text=f.business_id::text
    and a.member_id::text=f.member_id::text
    and a.id::text<>f.id::text
    and lower(coalesce(a.status::text,''))='active'
) active_matches on true
left join lateral (
  select
    count(*)::integer as exact_active_counterpart_count,
    coalesce(jsonb_agg(jsonb_build_object(
      'loan_id',a.id,
      'asset_name',a.asset_name,
      'loan_value',a.loan_value,
      'total_payable',a.total_payable,
      'start_date',a.start_date
    ) order by a.created_at),'[]'::jsonb) as active_counterparts
  from public.pb_loans a
  where a.business_id::text=f.business_id::text
    and a.member_id::text=f.member_id::text
    and a.id::text<>f.id::text
    and lower(coalesce(a.status::text,''))='active'
    and (
      (
        coalesce(a.order_id::text,'')<>''
        and coalesce(a.order_id::text,'')=coalesce(f.order_id::text,'')
      )
      or (
        lower(regexp_replace(trim(coalesce(a.asset_name,'')),'[[:space:]]+',' ','g'))
          =lower(regexp_replace(trim(coalesce(f.asset_name,'')),'[[:space:]]+',' ','g'))
        and abs(coalesce(a.loan_value,0)-coalesce(f.loan_value,0))<0.01
      )
    )
) exact_matches on true
left join lateral (
  select coalesce(jsonb_agg(to_jsonb(event_row) order by event_row.created_at desc),'[]'::jsonb) as latest_actions
  from (
    select a.created_at,a.staff_name,a.action,a.old_value,a.new_value
    from public.pb_audit_log a
    where a.business_id::text=f.business_id::text
      and a.entity_id::text=f.id::text
    order by a.created_at desc
    limit 5
  ) event_row
) recent_audit on true
order by
  coalesce(exact_matches.exact_active_counterpart_count,0) desc,
  f.shortfall desc,
  m.full_name;
