-- Wamama Pamoja Enterprise
-- Repair missing current group links without changing money, repayments or savings.
-- Safe to run more than once.

begin;

-- Keep an audit snapshot of only the rows this repair may update.
create table if not exists public.pb_missing_group_links_backup_20260805
as
select 'member'::text as record_type, id::text as record_id,
       member_id::text as member_id, group_id::text as group_id,
       officer_id::text as officer_id, now() as backed_up_at
from public.pb_loans
where false;

insert into public.pb_missing_group_links_backup_20260805
  (record_type, record_id, member_id, group_id, officer_id, backed_up_at)
select 'member', m.id::text, m.id::text, m.group_id::text, m.officer_id::text, now()
from public.pb_members m
where (m.group_id is null or not exists (
  select 1 from public.pb_groups g where g.id::text = m.group_id::text
))
and not exists (
  select 1 from public.pb_missing_group_links_backup_20260805 b
  where b.record_type='member' and b.record_id=m.id::text
);

insert into public.pb_missing_group_links_backup_20260805
  (record_type, record_id, member_id, group_id, officer_id, backed_up_at)
select 'loan', l.id::text, l.member_id::text, l.group_id::text, l.officer_id::text, now()
from public.pb_loans l
where lower(coalesce(l.status,'active')) not in ('completed','cancelled')
and (l.group_id is null or not exists (
  select 1 from public.pb_groups g where g.id::text = l.group_id::text
))
and not exists (
  select 1 from public.pb_missing_group_links_backup_20260805 b
  where b.record_type='loan' and b.record_id=l.id::text
);

-- Recover a member only when their current/open loans point to exactly one valid group.
with member_candidates as (
  select m.id::text as member_id,
         min(l.group_id::text) as group_id,
         count(distinct l.group_id::text) as group_count
  from public.pb_members m
  join public.pb_loans l on l.member_id::text = m.id::text
  join public.pb_groups g on g.id::text = l.group_id::text
  where (m.group_id is null or not exists (
    select 1 from public.pb_groups gx where gx.id::text = m.group_id::text
  ))
  and lower(coalesce(l.status,'active')) not in ('completed','cancelled')
  group by m.id::text
), unambiguous as (
  select mc.member_id, g.id as group_id, g.officer_id
  from member_candidates mc
  join public.pb_groups g on g.id::text = mc.group_id
  where mc.group_count = 1
)
update public.pb_members m
set group_id = u.group_id,
    officer_id = coalesce(u.officer_id, m.officer_id)
from unambiguous u
where m.id::text = u.member_id;

-- Current/open loans inherit a valid group from their member.
update public.pb_loans l
set group_id = m.group_id,
    officer_id = coalesce(g.officer_id, l.officer_id)
from public.pb_members m
join public.pb_groups g on g.id::text = m.group_id::text
where l.member_id::text = m.id::text
  and lower(coalesce(l.status,'active')) not in ('completed','cancelled')
  and (l.group_id is null or not exists (
    select 1 from public.pb_groups gx where gx.id::text = l.group_id::text
  ));

-- Current/open orders inherit the same group. Historical closed orders remain unchanged.
update public.pb_orders o
set group_id = m.group_id
from public.pb_members m
join public.pb_groups g on g.id::text = m.group_id::text
where o.member_id::text = m.id::text
  and lower(coalesce(o.status,'pending')) not in ('fulfilled','rejected','cancelled')
  and (o.group_id is null or not exists (
    select 1 from public.pb_groups gx where gx.id::text = o.group_id::text
  ));

commit;

-- Anything listed here needs the administrator to choose a group manually
-- from Members > three dots > Edit details.
select
  m.id,
  m.full_name,
  m.phone,
  m.group_id,
  'Select the correct group using Edit details' as action_required
from public.pb_members m
where m.group_id is null
   or not exists (select 1 from public.pb_groups g where g.id::text=m.group_id::text)
order by m.full_name;
