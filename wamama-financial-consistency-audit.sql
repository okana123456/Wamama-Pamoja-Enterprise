-- Wamama Pamoja Enterprise
-- Read-only financial consistency and synchronization audit.
-- This script does not update or delete any business or financial record.

with target_business as (
  select s.business_id::text as business_id
  from public.pb_staff s
  where lower(coalesce(s.email, '')) = 'wamamapamojaent@gmail.com'
  order by case when lower(coalesce(s.status, 'active')) = 'active' then 0 else 1 end
  limit 1
),
approved_totals as (
  select r.loan_id::text as loan_id,
         sum(coalesce(r.amount, 0))::numeric as total_paid
  from public.pb_repayments r
  join target_business b on b.business_id = r.business_id::text
  where lower(coalesce(r.status::text, 'approved'))
        not in ('pending', 'rejected', 'cancelled')
  group by r.loan_id::text
),
loan_health as (
  select l.*,
         coalesce(t.total_paid, 0)::numeric as approved_paid,
         case
           when l.start_date is null or l.start_date::date > current_date then 0::numeric
           else least(
             coalesce(l.total_payable, 0)::numeric,
             (greatest(1, floor((current_date - l.start_date::date) / 7.0)::integer + 1)
               * coalesce(l.weekly_installment, 0))::numeric
           )
         end as expected_paid_today
  from public.pb_loans l
  join target_business b on b.business_id = l.business_id::text
  left join approved_totals t on t.loan_id = l.id::text
),
exact_duplicate_groups as (
  select
    l.member_id::text as member_id,
    coalesce(l.order_id::text, '') as order_id,
    coalesce(l.asset_id::text, '') as asset_id,
    lower(trim(coalesce(l.asset_name, ''))) as asset_name,
    coalesce(l.loan_value, 0)::numeric as loan_value,
    l.start_date::date as start_date,
    count(*)::integer as duplicate_rows,
    array_agg(l.id::text order by l.created_at) as loan_ids
  from loan_health l
  where lower(coalesce(l.status::text, '')) = 'active'
    and l.member_id is not null
  group by l.member_id::text,
           coalesce(l.order_id::text, ''),
           coalesce(l.asset_id::text, ''),
           lower(trim(coalesce(l.asset_name, ''))),
           coalesce(l.loan_value, 0)::numeric,
           l.start_date::date
  having count(*) > 1
),
audit_sections as (
  select 1 as section_order, '01_business_scope'::text as section,
    jsonb_build_object(
      'business_id', (select business_id from target_business),
      'members', (select count(*) from public.pb_members m join target_business b on b.business_id=m.business_id::text),
      'loans', (select count(*) from loan_health),
      'repayments', (select count(*) from public.pb_repayments r join target_business b on b.business_id=r.business_id::text),
      'audit_rows', (select count(*) from public.pb_audit_log a join target_business b on b.business_id=a.business_id::text)
    ) as result

  union all

  select 2, '02_repayment_status_and_delay',
    jsonb_build_object(
      'approved_total', (select count(*) from public.pb_repayments r join target_business b on b.business_id=r.business_id::text where lower(coalesce(r.status::text,''))='approved'),
      'approved_last_7_days', (select count(*) from public.pb_repayments r join target_business b on b.business_id=r.business_id::text where lower(coalesce(r.status::text,''))='approved' and r.updated_at >= now()-interval '7 days'),
      'pending_now', (select count(*) from public.pb_repayments r join target_business b on b.business_id=r.business_id::text where lower(coalesce(r.status::text,'pending'))='pending'),
      'pending_over_15_minutes', (select count(*) from public.pb_repayments r join target_business b on b.business_id=r.business_id::text where lower(coalesce(r.status::text,'pending'))='pending' and r.created_at < now()-interval '15 minutes'),
      'pending_over_24_hours', (select count(*) from public.pb_repayments r join target_business b on b.business_id=r.business_id::text where lower(coalesce(r.status::text,'pending'))='pending' and r.created_at < now()-interval '24 hours'),
      'approved_missing_loan_link', (select count(*) from public.pb_repayments r join target_business b on b.business_id=r.business_id::text left join public.pb_loans l on l.id::text=r.loan_id::text where lower(coalesce(r.status::text,''))='approved' and (r.loan_id is null or l.id is null)),
      'approved_missing_member_link', (select count(*) from public.pb_repayments r join target_business b on b.business_id=r.business_id::text left join public.pb_members m on m.id::text=r.member_id::text where lower(coalesce(r.status::text,''))='approved' and (r.member_id is null or m.id is null))
    )

  union all

  select 3, '03_loan_and_arrears_consistency',
    jsonb_build_object(
      'active_loans', (select count(*) from loan_health where lower(coalesce(status::text,''))='active'),
      'active_fully_paid_should_be_zero', (select count(*) from loan_health where lower(coalesce(status::text,''))='active' and coalesce(total_payable,0)>0 and approved_paid+0.01>=coalesce(total_payable,0)),
      'completed_but_underpaid_for_review', (select count(*) from loan_health where lower(coalesce(status::text,''))='completed' and approved_paid+0.01<coalesce(total_payable,0)),
      'active_loans_currently_in_arrears', (select count(*) from loan_health where lower(coalesce(status::text,''))='active' and greatest(0,expected_paid_today-approved_paid-5)>0),
      'active_loans_with_zero_calculated_arrears', (select count(*) from loan_health where lower(coalesce(status::text,''))='active' and greatest(0,expected_paid_today-approved_paid-5)=0),
      'exact_active_duplicate_groups', (select count(*) from exact_duplicate_groups)
    )

  union all

  select 4, '04_exact_active_duplicate_details',
    coalesce((
      select jsonb_agg(to_jsonb(d) order by d.member_name, d.start_date)
      from (
        select m.full_name as member_name, m.phone, g.*
        from exact_duplicate_groups g
        left join public.pb_members m on m.id::text=g.member_id
        order by m.full_name, g.start_date
        limit 100
      ) d
    ), '[]'::jsonb)

  union all

  select 5, '05_deleted_loan_audit_check',
    jsonb_build_object(
      'duplicate_deletion_events_last_90_days', (
        select count(*) from public.pb_audit_log a join target_business b on b.business_id=a.business_id::text
        where a.action='delete_duplicate_loan' and a.created_at>=now()-interval '90 days'
      ),
      'deleted_ids_present_again_in_database', (
        select count(*) from public.pb_audit_log a join target_business b on b.business_id=a.business_id::text
        join public.pb_loans l on l.id::text=a.entity_id::text
        where a.action='delete_duplicate_loan' and a.created_at>=now()-interval '90 days'
      ),
      'interpretation', 'If deleted_ids_present_again_in_database is zero but a device still displays them, the device has stale cached rows rather than restored database loans.'
    )

  union all

  select 6, '06_audit_trail_coverage_last_30_days',
    jsonb_build_object(
      'all_audit_events', (select count(*) from public.pb_audit_log a join target_business b on b.business_id=a.business_id::text where a.created_at>=now()-interval '30 days'),
      'repayment_related_events', (select count(*) from public.pb_audit_log a join target_business b on b.business_id=a.business_id::text where a.created_at>=now()-interval '30 days' and (lower(coalesce(a.action,'')) like '%repay%' or lower(coalesce(a.entity,'')) like '%repay%')),
      'loan_related_events', (select count(*) from public.pb_audit_log a join target_business b on b.business_id=a.business_id::text where a.created_at>=now()-interval '30 days' and (lower(coalesce(a.action,'')) like '%loan%' or lower(coalesce(a.entity,'')) like '%loan%')),
      'latest_event_at', (select max(a.created_at) from public.pb_audit_log a join target_business b on b.business_id=a.business_id::text)
    )

  union all

  select 7, '07_required_database_safeguards',
    coalesce((
      select jsonb_agg(to_jsonb(x) order by x.safeguard)
      from (
        select required.safeguard,
               exists (
                 select 1
                 from pg_trigger t
                 join pg_class c on c.oid=t.tgrelid
                 join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='public' and c.relname=required.table_name
                   and t.tgname=required.safeguard and not t.tgisinternal
               ) as installed
        from (values
          ('pb_loans','pb_block_exact_duplicate_active_loans_trigger'),
          ('pb_repayments','pb_block_rapid_duplicate_pending_repayment_trigger'),
          ('pb_repayments','trg_pb_repayment_auto_close_loan'),
          ('pb_loans','pb_touch_updated_at_trigger'),
          ('pb_repayments','pb_touch_updated_at_trigger')
        ) required(table_name,safeguard)
      ) x
    ), '[]'::jsonb)

  union all

  select 8, '08_recent_database_activity',
    jsonb_build_object(
      'latest_loan_update', (select max(updated_at) from loan_health),
      'latest_repayment_update', (select max(r.updated_at) from public.pb_repayments r join target_business b on b.business_id=r.business_id::text),
      'loans_updated_last_24_hours', (select count(*) from loan_health where updated_at>=now()-interval '24 hours'),
      'repayments_updated_last_24_hours', (select count(*) from public.pb_repayments r join target_business b on b.business_id=r.business_id::text where r.updated_at>=now()-interval '24 hours')
    )
)
select section_order, section, result
from audit_sections
order by section_order;
