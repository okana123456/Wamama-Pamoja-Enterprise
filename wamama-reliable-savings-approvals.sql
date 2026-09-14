-- Wamama reliable savings approvals
-- Safe to run more than once. Existing savings amounts are not changed.

begin;

alter table public.pb_permissions
  add column if not exists can_approve_savings boolean not null default false;

create or replace function public.pb_approve_savings(p_saving_ids text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.pb_staff%rowtype;
  v_allowed boolean := false;
  v_requested integer := 0;
  v_rows jsonb := '[]'::jsonb;
begin
  select s.* into v_staff
  from public.pb_staff s
  where s.auth_user_id = auth.uid()
    and lower(coalesce(s.status,'active')) = 'active'
  limit 1;

  if not found then
    raise exception 'Your Wamama staff session was not found.';
  end if;

  select (
    lower(coalesce(v_staff.role,'')) in ('admin','ceo','branch_manager','supervisor')
    or coalesce(p.can_approve_savings,false)
  ) into v_allowed
  from public.pb_permissions p
  where p.staff_id::text = v_staff.id::text
  limit 1;

  v_allowed := coalesce(
    v_allowed,
    lower(coalesce(v_staff.role,'')) in ('admin','ceo','branch_manager','supervisor')
  );

  if not v_allowed then
    raise exception 'You do not have permission to approve savings.';
  end if;

  select count(*) into v_requested
  from unnest(coalesce(p_saving_ids,array[]::text[])) requested_id
  where nullif(trim(requested_id),'') is not null;

  if v_requested = 0 then
    raise exception 'Select at least one savings entry to approve.';
  end if;

  with approved as (
    update public.pb_savings s
    set status = 'approved', updated_at = now()
    where s.id::text = any(p_saving_ids)
      and s.business_id::text = v_staff.business_id::text
      and lower(coalesce(s.status,'pending')) = 'pending'
    returning s.*
  )
  select coalesce(jsonb_agg(to_jsonb(approved)),'[]'::jsonb)
  into v_rows
  from approved;

  return jsonb_build_object(
    'requested_count',v_requested,
    'approved_count',jsonb_array_length(v_rows),
    'rows',v_rows
  );
end;
$$;

revoke all on function public.pb_approve_savings(text[]) from public;
grant execute on function public.pb_approve_savings(text[]) to authenticated;

commit;

select
  count(*) filter (where lower(coalesce(status,'pending'))='pending') as pending_savings,
  count(*) filter (where lower(coalesce(status,'pending'))='approved') as approved_savings
from public.pb_savings;
