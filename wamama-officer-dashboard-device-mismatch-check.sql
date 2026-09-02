-- Wamama officer dashboard mismatch check.
-- Read-only: confirms what the database currently assigns to the officer.
-- Change the officer_name_search value if checking another officer.

with params as (
  select '%Carlox%Ogolla%'::text as officer_name_search
),
officer as (
  select id, business_id, full_name, role, app_role, status, team_name
  from public.pb_staff, params
  where full_name ilike params.officer_name_search
  order by status desc, full_name
  limit 1
),
officer_groups as (
  select g.*
  from public.pb_groups g
  join officer o on o.id = g.officer_id and o.business_id = g.business_id
),
officer_members as (
  select m.*
  from public.pb_members m
  join officer_groups g on g.id = m.group_id and g.business_id = m.business_id
),
officer_active_loans as (
  select l.*
  from public.pb_loans l
  join officer o on o.business_id = l.business_id
  where l.status = 'active'
    and (
      l.officer_id = o.id
      or l.group_id in (select id from officer_groups)
      or l.member_id in (select id from officer_members)
    )
),
arrears as (
  select l.*
  from officer_active_loans l
  where coalesce(l.arrears_amount,0) > 0
     or coalesce(l.overdue_days,0) > 0
     or greatest(0, coalesce(l.total_payable,0) - coalesce(l.total_paid,0)) > 0
),
summary as (
  select
    1 as section_order,
    'database_officer_summary' as section,
    jsonb_build_object(
      'officer_name', (select full_name from officer),
      'officer_id', (select id from officer),
      'officer_status', (select status from officer),
      'assigned_groups', (select count(*) from officer_groups),
      'active_assigned_groups', (select count(*) from officer_groups where status = 'active'),
      'members_in_assigned_groups', (select count(*) from officer_members),
      'active_loans_visible_to_officer', (select count(*) from officer_active_loans),
      'accounts_with_arrears_or_balance', (select count(*) from arrears)
    ) as result
),
groups_detail as (
  select
    2 as section_order,
    'assigned_groups_detail' as section,
    coalesce(jsonb_agg(jsonb_build_object(
      'group_name', g.name,
      'group_status', g.status,
      'meeting_day', g.meeting_day,
      'members', (select count(*) from public.pb_members m where m.group_id = g.id),
      'active_loans', (select count(*) from public.pb_loans l where l.group_id = g.id and l.status = 'active')
    ) order by g.name), '[]'::jsonb) as result
  from officer_groups g
)
select * from summary
union all
select * from groups_detail
order by section_order;
