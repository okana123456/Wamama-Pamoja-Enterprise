-- Wamama officer dashboard mismatch check.
-- Read-only: lists every matching staff account and its current database portfolio.
-- Change officer_name_search when checking a different officer.

with params as (
  select '%Ogolla%'::text as officer_name_search
),
matching_officers as (
  select s.id, s.business_id, s.full_name, s.role, s.status, s.auth_user_id
  from public.pb_staff s
  cross join params p
  where s.full_name ilike p.officer_name_search
),
officer_summary as (
  select
    o.id,
    o.full_name,
    o.role,
    o.status,
    o.auth_user_id,
    (select count(*) from public.pb_groups g
      where g.business_id = o.business_id and g.officer_id = o.id) as assigned_groups,
    (select count(*) from public.pb_groups g
      where g.business_id = o.business_id and g.officer_id = o.id and g.status = 'active') as active_assigned_groups,
    (select count(*)
      from public.pb_members m
      join public.pb_groups g on g.id = m.group_id and g.business_id = m.business_id
      where g.business_id = o.business_id and g.officer_id = o.id) as members_in_assigned_groups,
    (select count(*)
      from public.pb_loans l
      where l.business_id = o.business_id
        and l.status = 'active'
        and (
          l.officer_id = o.id
          or l.group_id in (
            select g.id from public.pb_groups g
            where g.business_id = o.business_id and g.officer_id = o.id
          )
        )) as active_loans_visible_to_officer
  from matching_officers o
),
matches as (
  select
    1 as section_order,
    'matching_staff_accounts' as section,
    coalesce(jsonb_agg(to_jsonb(o) order by o.full_name), '[]'::jsonb) as result
  from officer_summary o
),
groups_detail as (
  select
    2 as section_order,
    'assigned_groups_detail' as section,
    coalesce(jsonb_agg(jsonb_build_object(
      'officer_name', o.full_name,
      'officer_id', o.id,
      'group_name', g.name,
      'group_status', g.status,
      'meeting_day', g.meeting_day,
      'members', (select count(*) from public.pb_members m where m.group_id = g.id),
      'active_loans', (select count(*) from public.pb_loans l where l.group_id = g.id and l.status = 'active')
    ) order by o.full_name, g.name), '[]'::jsonb) as result
  from matching_officers o
  join public.pb_groups g on g.business_id = o.business_id and g.officer_id = o.id
)
select * from matches
union all
select * from groups_detail
order by section_order;
