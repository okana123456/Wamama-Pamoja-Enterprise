-- Wamama Pamoja Enterprise
-- Team supervisor access + flexible officer portfolio transfer
-- Run this in Supabase SQL Editor to replace the earlier transfer function.

alter table public.pb_staff
  add column if not exists team_name text;

create index if not exists idx_pb_staff_business_team
  on public.pb_staff (business_id, team_name);

create index if not exists idx_pb_groups_business_officer
  on public.pb_groups (business_id, officer_id);

create index if not exists idx_pb_members_business_officer
  on public.pb_members (business_id, officer_id);

create index if not exists idx_pb_loans_business_officer_status
  on public.pb_loans (business_id, officer_id, status);

create index if not exists idx_pb_orders_business_recorded_status
  on public.pb_orders (business_id, recorded_by, status);

-- This version uses text parameters because this project stores staff IDs as text.
-- It also supports partial/split transfer using transfer_group_ids.
create or replace function public.pb_transfer_officer_book(
  from_officer_id text,
  to_officer_id text,
  transfer_group_ids text[] default array[]::text[],
  transfer_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id public.pb_staff.business_id%type;
  v_from_name text;
  v_to_name text;
  v_groups int := 0;
  v_members int := 0;
  v_loans int := 0;
  v_orders int := 0;
  v_actor_id public.pb_staff.id%type;
  v_actor_name text;
  v_split_mode boolean := coalesce(array_length(transfer_group_ids, 1), 0) > 0;
begin
  if nullif(trim(from_officer_id), '') is null or nullif(trim(to_officer_id), '') is null then
    raise exception 'Both officers are required.';
  end if;

  if from_officer_id = to_officer_id then
    raise exception 'Transfer from and transfer to cannot be the same officer.';
  end if;

  select business_id, full_name
    into v_business_id, v_from_name
  from public.pb_staff
  where id::text = from_officer_id
    and status = 'active'
  limit 1;

  if v_business_id is null then
    raise exception 'The source officer was not found or is inactive.';
  end if;

  select full_name
    into v_to_name
  from public.pb_staff
  where id::text = to_officer_id
    and business_id = v_business_id
    and status = 'active'
  limit 1;

  if v_to_name is null then
    raise exception 'The receiving officer was not found in the same business or is inactive.';
  end if;

  select id, full_name
    into v_actor_id, v_actor_name
  from public.pb_staff
  where auth_user_id = auth.uid()
    and business_id = v_business_id
  limit 1;

  if not v_split_mode then
    update public.pb_groups
       set officer_id = to_officer_id
     where business_id = v_business_id
       and officer_id::text = from_officer_id;
    get diagnostics v_groups = row_count;

    update public.pb_members
       set officer_id = to_officer_id
     where business_id = v_business_id
       and officer_id::text = from_officer_id;
    get diagnostics v_members = row_count;

    update public.pb_loans
       set officer_id = to_officer_id
     where business_id = v_business_id
       and officer_id::text = from_officer_id
       and coalesce(status, '') not in ('completed', 'cancelled');
    get diagnostics v_loans = row_count;

    update public.pb_orders
       set recorded_by = to_officer_id
     where business_id = v_business_id
       and recorded_by::text = from_officer_id
       and coalesce(status, '') not in ('fulfilled', 'rejected', 'cancelled');
    get diagnostics v_orders = row_count;
  else
    update public.pb_groups
       set officer_id = to_officer_id
     where business_id = v_business_id
       and officer_id::text = from_officer_id
       and id::text = any(transfer_group_ids);
    get diagnostics v_groups = row_count;

    update public.pb_members
       set officer_id = to_officer_id
     where business_id = v_business_id
       and group_id::text = any(transfer_group_ids);
    get diagnostics v_members = row_count;

    update public.pb_loans
       set officer_id = to_officer_id
     where business_id = v_business_id
       and coalesce(status, '') not in ('completed', 'cancelled')
       and (
         group_id::text = any(transfer_group_ids)
         or member_id::text in (
           select id::text from public.pb_members
           where business_id = v_business_id
             and group_id::text = any(transfer_group_ids)
         )
       );
    get diagnostics v_loans = row_count;

    update public.pb_orders
       set recorded_by = to_officer_id
     where business_id = v_business_id
       and coalesce(status, '') not in ('fulfilled', 'rejected', 'cancelled')
       and (
         group_id::text = any(transfer_group_ids)
         or member_id::text in (
           select id::text from public.pb_members
           where business_id = v_business_id
             and group_id::text = any(transfer_group_ids)
         )
       );
    get diagnostics v_orders = row_count;
  end if;

  insert into public.pb_audit_log (
    business_id,
    staff_id,
    staff_name,
    action,
    entity,
    entity_id,
    old_value,
    new_value
  )
  values (
    v_business_id,
    v_actor_id,
    coalesce(v_actor_name, 'System'),
    case when v_split_mode then 'split_officer_portfolio' else 'transfer_officer_book' end,
    'pb_staff',
    from_officer_id,
    jsonb_build_object(
      'from_officer_id', from_officer_id,
      'from_officer_name', v_from_name
    ),
    jsonb_build_object(
      'to_officer_id', to_officer_id,
      'to_officer_name', v_to_name,
      'split_mode', v_split_mode,
      'group_ids', transfer_group_ids,
      'groups_transferred', v_groups,
      'members_transferred', v_members,
      'open_loans_transferred', v_loans,
      'open_orders_transferred', v_orders,
      'note', transfer_note
    )
  );

  return jsonb_build_object(
    'success', true,
    'mode', case when v_split_mode then 'split_selected_groups' else 'whole_book' end,
    'from_officer', v_from_name,
    'to_officer', v_to_name,
    'groups_transferred', v_groups,
    'members_transferred', v_members,
    'open_loans_transferred', v_loans,
    'open_orders_transferred', v_orders
  );
end;
$$;

grant execute on function public.pb_transfer_officer_book(text, text, text[], text) to authenticated;

-- If the earlier UUID version exists, leave it harmlessly in place.
-- The app now calls this text version with transfer_group_ids.
