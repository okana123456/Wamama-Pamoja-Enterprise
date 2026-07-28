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

-- The browser sends IDs as text, while the live Wamama tables use UUID and
-- legacy-compatible ID columns. The function resolves the correct type per table.
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
  v_from_staff_id public.pb_staff.id%type;
  v_to_staff_id public.pb_staff.id%type;
  v_from_group_officer_id public.pb_groups.officer_id%type;
  v_to_group_officer_id public.pb_groups.officer_id%type;
  v_from_member_officer_id public.pb_members.officer_id%type;
  v_to_member_officer_id public.pb_members.officer_id%type;
  v_from_loan_officer_id public.pb_loans.officer_id%type;
  v_to_loan_officer_id public.pb_loans.officer_id%type;
  v_from_order_recorder_id public.pb_orders.recorded_by%type;
  v_to_order_recorder_id public.pb_orders.recorded_by%type;
  v_from_name text;
  v_to_name text;
  v_groups int := 0;
  v_members int := 0;
  v_loans int := 0;
  v_orders int := 0;
  v_actor_id public.pb_staff.id%type;
  v_actor_name text;
  v_split_mode boolean := coalesce(array_length(transfer_group_ids, 1), 0) > 0;
  v_portfolio_group_ids text[] := array[]::text[];
  v_requested_groups int := 0;
begin
  if nullif(trim(from_officer_id), '') is null or nullif(trim(to_officer_id), '') is null then
    raise exception 'Both officers are required.';
  end if;

  if from_officer_id = to_officer_id then
    raise exception 'Transfer from and transfer to cannot be the same officer.';
  end if;

  select id, business_id, full_name
    into v_from_staff_id, v_business_id, v_from_name
  from public.pb_staff
  where id::text = from_officer_id
    and status = 'active'
  limit 1;

  if v_business_id is null then
    raise exception 'The source officer was not found or is inactive.';
  end if;

  select id, full_name
    into v_to_staff_id, v_to_name
  from public.pb_staff
  where id::text = to_officer_id
    and business_id = v_business_id
    and status = 'active'
  limit 1;

  if v_to_name is null then
    raise exception 'The receiving officer was not found in the same business or is inactive.';
  end if;

  -- Resolve each destination value using the exact column type in this project.
  -- This prevents text/UUID mismatches even if legacy tables use mixed ID types.
  v_from_group_officer_id := v_from_staff_id::text;
  v_to_group_officer_id := v_to_staff_id::text;
  v_from_member_officer_id := v_from_staff_id::text;
  v_to_member_officer_id := v_to_staff_id::text;
  v_from_loan_officer_id := v_from_staff_id::text;
  v_to_loan_officer_id := v_to_staff_id::text;
  v_from_order_recorder_id := v_from_staff_id::text;
  v_to_order_recorder_id := v_to_staff_id::text;

  -- Capture the source officer's groups before changing any assignments.
  -- This also prevents stale selections from moving another officer's groups.
  if v_split_mode then
    select count(*) into v_requested_groups
    from unnest(transfer_group_ids) as requested_group_id;

    select coalesce(array_agg(g.id::text), array[]::text[])
      into v_portfolio_group_ids
    from public.pb_groups g
    where g.business_id = v_business_id
      and g.officer_id = v_from_group_officer_id
      and g.id::text = any(transfer_group_ids);

    if coalesce(array_length(v_portfolio_group_ids, 1), 0) <> v_requested_groups then
      raise exception 'One or more selected groups are no longer assigned to the source officer. Refresh and select the groups again.';
    end if;
  else
    select coalesce(array_agg(g.id::text), array[]::text[])
      into v_portfolio_group_ids
    from public.pb_groups g
    where g.business_id = v_business_id
      and g.officer_id = v_from_group_officer_id;
  end if;

  select id, full_name
    into v_actor_id, v_actor_name
  from public.pb_staff
  where auth_user_id = auth.uid()
    and business_id = v_business_id
  limit 1;

  if not v_split_mode then
    update public.pb_groups
       set officer_id = v_to_group_officer_id
     where business_id = v_business_id
       and officer_id = v_from_group_officer_id;
    get diagnostics v_groups = row_count;

    update public.pb_members
       set officer_id = v_to_member_officer_id
     where business_id = v_business_id
       and (
         officer_id = v_from_member_officer_id
         or group_id::text = any(v_portfolio_group_ids)
       );
    get diagnostics v_members = row_count;

    update public.pb_loans
       set officer_id = v_to_loan_officer_id
     where business_id = v_business_id
       and coalesce(status, '') not in ('completed', 'cancelled')
       and (
         officer_id = v_from_loan_officer_id
         or group_id::text = any(v_portfolio_group_ids)
         or member_id::text in (
           select id::text from public.pb_members
           where business_id = v_business_id
             and group_id::text = any(v_portfolio_group_ids)
         )
       );
    get diagnostics v_loans = row_count;

    update public.pb_orders
       set recorded_by = v_to_order_recorder_id
     where business_id = v_business_id
       and coalesce(status, '') not in ('fulfilled', 'rejected', 'cancelled')
       and (
         recorded_by = v_from_order_recorder_id
         or group_id::text = any(v_portfolio_group_ids)
         or member_id::text in (
           select id::text from public.pb_members
           where business_id = v_business_id
             and group_id::text = any(v_portfolio_group_ids)
         )
       );
    get diagnostics v_orders = row_count;
  else
    update public.pb_groups
       set officer_id = v_to_group_officer_id
     where business_id = v_business_id
       and officer_id = v_from_group_officer_id
       and id::text = any(v_portfolio_group_ids);
    get diagnostics v_groups = row_count;

    update public.pb_members
       set officer_id = v_to_member_officer_id
     where business_id = v_business_id
       and group_id::text = any(v_portfolio_group_ids);
    get diagnostics v_members = row_count;

    update public.pb_loans
       set officer_id = v_to_loan_officer_id
     where business_id = v_business_id
       and coalesce(status, '') not in ('completed', 'cancelled')
       and (
         group_id::text = any(v_portfolio_group_ids)
         or member_id::text in (
           select id::text from public.pb_members
           where business_id = v_business_id
             and group_id::text = any(v_portfolio_group_ids)
         )
       );
    get diagnostics v_loans = row_count;

    update public.pb_orders
       set recorded_by = v_to_order_recorder_id
     where business_id = v_business_id
       and coalesce(status, '') not in ('fulfilled', 'rejected', 'cancelled')
       and (
         group_id::text = any(v_portfolio_group_ids)
         or member_id::text in (
           select id::text from public.pb_members
           where business_id = v_business_id
             and group_id::text = any(v_portfolio_group_ids)
         )
       );
    get diagnostics v_orders = row_count;
  end if;

  if (v_groups + v_members + v_loans + v_orders) = 0 then
    raise exception 'No current groups, clients, open loans or open orders were found for this transfer.';
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
      'group_ids', v_portfolio_group_ids,
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
