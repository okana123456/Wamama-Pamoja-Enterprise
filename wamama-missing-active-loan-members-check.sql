-- Wamama Pamoja Enterprise
-- Active loans without client names
--
-- Cause: some sold-items/order rows created active loans without member_id.
-- This file helps identify the affected loans, find likely members, and repair
-- only confirmed matches.

-- SECTION 1: List active loans whose member link is missing or broken.
-- No data is changed.
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
  l.weekly_installment,
  l.start_date,
  l.status,
  l.created_at,
  l.order_id,
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

-- SECTION 2: Suggest likely members using the original sold-items form rows.
-- No data is changed.
with missing_loans as (
  select l.*
  from public.pb_loans l
  left join public.pb_members m
    on m.id::text = l.member_id::text
  where l.status = 'active'
    and (l.member_id is null or m.id is null)
),
order_rows as (
  select
    ml.id as loan_id,
    ml.asset_name as loan_asset,
    ml.loan_value,
    ml.total_payable,
    ml.start_date,
    ml.group_id as loan_group_id,
    ml.officer_id as loan_officer_id,
    o.id as order_id,
    row_data.value as raw_row,
    row_data.value->>'client_name' as form_client_name,
    row_data.value->>'phone' as form_phone,
    row_data.value->>'product' as form_product,
    nullif(regexp_replace(coalesce(row_data.value->>'phone',''), '\D', '', 'g'), '') as form_phone_digits
  from missing_loans ml
  left join public.pb_orders o
    on o.id::text = ml.order_id::text
  left join lateral jsonb_array_elements(
    case
      when o.notes is not null
       and left(trim(o.notes), 1) = '{'
       and jsonb_typeof((o.notes::jsonb)->'rows') = 'array'
      then (o.notes::jsonb)->'rows'
      else '[]'::jsonb
    end
  ) as row_data(value) on true
),
best_rows as (
  select distinct on (loan_id)
    *
  from order_rows
  where
    lower(trim(coalesce(form_product,''))) = lower(trim(coalesce(loan_asset,'')))
    or abs(coalesce(nullif((raw_row->>'loan_amount'), '')::numeric, 0) - coalesce(loan_value, 0)) < 0.01
  order by loan_id,
    case when lower(trim(coalesce(form_product,''))) = lower(trim(coalesce(loan_asset,''))) then 0 else 1 end
),
candidate_members as (
  select
    br.loan_id,
    br.form_client_name,
    br.form_phone,
    br.form_product,
    br.loan_asset,
    br.loan_value,
    br.total_payable,
    br.start_date,
    g.name as loan_group,
    s.full_name as loan_officer,
    cm.id as possible_member_id,
    cm.full_name as possible_member_name,
    cm.phone as possible_member_phone,
    cg.name as possible_member_group,
    cs.full_name as possible_member_officer,
    case
      when br.form_phone_digits <> '' and right(regexp_replace(coalesce(cm.phone,''), '\D', '', 'g'), 9) = right(br.form_phone_digits, 9) then 'Phone match'
      when lower(trim(coalesce(cm.full_name,''))) = lower(trim(coalesce(br.form_client_name,''))) then 'Exact name match'
      when lower(coalesce(cm.full_name,'')) like '%' || lower(coalesce(split_part(br.form_client_name,' ',1),'')) || '%' then 'Possible name match'
      else 'Review manually'
    end as match_reason
  from best_rows br
  left join public.pb_groups g
    on g.id::text = br.loan_group_id::text
  left join public.pb_staff s
    on s.id::text = br.loan_officer_id::text
  left join public.pb_members cm
    on (
      (
        br.form_phone_digits <> ''
        and right(regexp_replace(coalesce(cm.phone,''), '\D', '', 'g'), 9) = right(br.form_phone_digits, 9)
      )
      or lower(trim(coalesce(cm.full_name,''))) = lower(trim(coalesce(br.form_client_name,'')))
    )
  left join public.pb_groups cg
    on cg.id::text = cm.group_id::text
  left join public.pb_staff cs
    on cs.id::text = cm.officer_id::text
)
select *
from candidate_members
order by start_date desc nulls last, loan_group, form_client_name;

-- SECTION 3: Repair one confirmed loan.
-- Replace the two IDs after confirming the correct member from Section 2.
-- This updates the loan, repayments, and matching order to the correct member.
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

-- SECTION 4: Confirm remaining active loans without names.
select count(*) as active_loans_without_member_names
from public.pb_loans l
left join public.pb_members m
  on m.id::text = l.member_id::text
where l.status = 'active'
  and (l.member_id is null or m.id is null);
