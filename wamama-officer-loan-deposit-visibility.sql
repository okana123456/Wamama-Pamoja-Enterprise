-- Wamama: read-only loan-deposit balances for responsible officers.
-- Run once in the Wamama Supabase SQL Editor. Existing ledger permissions,
-- loan balances and payment rows are unchanged.

begin;

create or replace function public.pb_visible_loan_deposit_balances()
returns table (
  member_id text,
  payment_date date,
  available_amount numeric
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff record;
begin
  select s.id::text as staff_id,
         s.business_id::text as business_id,
         lower(coalesce(s.role::text,'')) as role,
         lower(trim(coalesce(s.team_name::text,''))) as team_name
    into v_staff
  from public.pb_staff s
  where s.auth_user_id = auth.uid()
    and lower(coalesce(s.status::text,'active')) = 'active'
  limit 1;

  if v_staff.staff_id is null then
    raise exception 'An active Wamama staff session is required.';
  end if;
  if v_staff.role not in
       ('admin','ceo','branch_manager','supervisor','loan_officer','officer') then
    raise exception 'This account cannot view loan deposits.';
  end if;

  return query
  select ep.member_id::text,
         ep.payment_date::date,
         round(sum(greatest(0,
           coalesce(ep.excess_amount,0)-coalesce(ep.released_amount,0))),2)
  from public.pb_excess_payments ep
  join public.pb_members m
    on m.id::text = ep.member_id::text
   and m.business_id::text = v_staff.business_id
  join public.pb_groups g
    on g.id::text = m.group_id::text
   and g.business_id::text = v_staff.business_id
  where ep.business_id = v_staff.business_id
    and ep.status not in ('refunded','cancelled','rejected','transferred_to_savings')
    and ep.excess_amount > coalesce(ep.released_amount,0)
    and (
      v_staff.role in ('admin','ceo','branch_manager')
      or g.officer_id::text = v_staff.staff_id
      or (
        v_staff.role = 'supervisor'
        and v_staff.team_name <> ''
        and exists (
          select 1 from public.pb_staff team_officer
          where team_officer.id::text = g.officer_id::text
            and team_officer.business_id::text = v_staff.business_id
            and lower(coalesce(team_officer.status::text,'active')) = 'active'
            and lower(trim(coalesce(team_officer.team_name::text,''))) = v_staff.team_name
        )
      )
    )
  group by ep.member_id, ep.payment_date
  having sum(greatest(0,
    coalesce(ep.excess_amount,0)-coalesce(ep.released_amount,0))) > 0
  order by ep.member_id, ep.payment_date;
end;
$$;

revoke all on function public.pb_visible_loan_deposit_balances() from public, anon;
grant execute on function public.pb_visible_loan_deposit_balances() to authenticated;

commit;

select 'Officer loan-deposit balance view installed; no financial rows changed' as result;
