-- Wamama Pamoja Enterprise
-- Check active loans that show without client names because the loan is not linked
-- to an existing member record.
--
-- Run Section 1 first. It does not change any data.
-- Only use Section 2 after confirming the correct member_id for each loan.

-- SECTION 1: Find active loans whose member link is missing or broken.
select
  l.id as loan_id,
  l.member_id as stored_member_id,
  l.group_id as loan_group_id,
  g.name as loan_group,
  l.officer_id,
  s.full_name as officer_name,
  l.asset_name,
  l.loan_value,
  l.total_payable,
  l.start_date,
  l.status,
  l.created_at,
  case
    when l.member_id is null then 'Loan has no member_id'
    when m.id is null then 'Loan member_id does not exist in pb_members'
    else 'OK'
  end as finding
from public.pb_loans l
left join public.pb_members m
  on m.id::text = l.member_id::text
left join public.pb_groups g
  on g.id::text = l.group_id::text
left join public.pb_staff s
  on s.id::text = l.officer_id::text
where l.status = 'active'
  and (l.member_id is null or m.id is null)
order by l.start_date desc nulls last, l.created_at desc nulls last;

-- SECTION 2: Search members before repairing one loan.
-- Replace the search text with the client's name, phone, or group.
/*
select
  m.id as correct_member_id,
  m.full_name,
  m.phone,
  m.national_id,
  m.status,
  g.name as current_group,
  s.full_name as assigned_officer
from public.pb_members m
left join public.pb_groups g
  on g.id::text = m.group_id::text
left join public.pb_staff s
  on s.id::text = m.officer_id::text
where
  lower(coalesce(m.full_name,'')) like lower('%TYPE CLIENT NAME HERE%')
  or regexp_replace(coalesce(m.phone,''), '\D', '', 'g') like '%TYPE PHONE HERE%'
order by m.full_name;
*/

-- SECTION 3: Repair one confirmed loan.
-- Replace the two IDs after confirming from Sections 1 and 2.
-- This updates the loan, its repayments, and its orders to the correct member.
/*
do $$
declare
  v_loan_id uuid := 'PASTE_LOAN_ID_HERE';
  v_member_id uuid := 'PASTE_CORRECT_MEMBER_ID_HERE';
  v_group_id uuid;
  v_officer_id uuid;
begin
  select group_id, officer_id
    into v_group_id, v_officer_id
  from public.pb_members
  where id = v_member_id;

  if v_group_id is null then
    raise exception 'Selected member has no group_id. Edit the member group first.';
  end if;

  update public.pb_loans
     set member_id = v_member_id,
         group_id = v_group_id,
         officer_id = coalesce(v_officer_id, officer_id)
   where id = v_loan_id;

  update public.pb_repayments
     set member_id = v_member_id,
         group_id = v_group_id,
         officer_id = coalesce(v_officer_id, officer_id)
   where loan_id = v_loan_id;

  update public.pb_orders
     set member_id = v_member_id,
         group_id = v_group_id,
         officer_id = coalesce(v_officer_id, officer_id)
   where loan_id = v_loan_id;
end $$;
*/

-- SECTION 4: Confirm there are no remaining active loans without client names.
select count(*) as active_loans_without_member_names
from public.pb_loans l
left join public.pb_members m
  on m.id::text = l.member_id::text
where l.status = 'active'
  and (l.member_id is null or m.id is null);
