-- Wamama Pamoja Enterprise
-- Team supervisor access + officer book transfer setup
-- Run this once in Supabase SQL Editor.

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

create or replace function public.pb_transfer_officer_book(
  from_officer_id uuid,
  to_officer_id uuid,
  transfer_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id uuid;
  v_from_name text;
  v_to_name text;
  v_groups int := 0;
  v_members int := 0;
  v_loans int := 0;
  v_orders int := 0;
  v_actor_id uuid;
  v_actor_name text;
begin
  if from_officer_id is null or to_officer_id is null then
    raise exception 'Both officers are required.';
  end if;

  if from_officer_id = to_officer_id then
    raise exception 'Transfer from and transfer to cannot be the same officer.';
  end if;

  select business_id, full_name
    into v_business_id, v_from_name
  from public.pb_staff
  where id = from_officer_id
    and status = 'active';

  if v_business_id is null then
    raise exception 'The source officer was not found or is inactive.';
  end if;

  select full_name
    into v_to_name
  from public.pb_staff
  where id = to_officer_id
    and business_id = v_business_id
    and status = 'active';

  if v_to_name is null then
    raise exception 'The receiving officer was not found in the same business or is inactive.';
  end if;

  select id, full_name
    into v_actor_id, v_actor_name
  from public.pb_staff
  where auth_user_id = auth.uid()
    and business_id = v_business_id
  limit 1;

  update public.pb_groups
     set officer_id = to_officer_id
   where business_id = v_business_id
     and officer_id = from_officer_id;
  get diagnostics v_groups = row_count;

  update public.pb_members
     set officer_id = to_officer_id
   where business_id = v_business_id
     and officer_id = from_officer_id;
  get diagnostics v_members = row_count;

  update public.pb_loans
     set officer_id = to_officer_id
   where business_id = v_business_id
     and officer_id = from_officer_id
     and coalesce(status, '') not in ('completed', 'cancelled');
  get diagnostics v_loans = row_count;

  update public.pb_orders
     set recorded_by = to_officer_id
   where business_id = v_business_id
     and recorded_by = from_officer_id
     and coalesce(status, '') not in ('fulfilled', 'rejected', 'cancelled');
  get diagnostics v_orders = row_count;

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
    'transfer_officer_book',
    'pb_staff',
    from_officer_id::text,
    jsonb_build_object(
      'from_officer_id', from_officer_id,
      'from_officer_name', v_from_name
    ),
    jsonb_build_object(
      'to_officer_id', to_officer_id,
      'to_officer_name', v_to_name,
      'groups_transferred', v_groups,
      'members_transferred', v_members,
      'open_loans_transferred', v_loans,
      'open_orders_transferred', v_orders,
      'note', transfer_note
    )
  );

  return jsonb_build_object(
    'success', true,
    'from_officer', v_from_name,
    'to_officer', v_to_name,
    'groups_transferred', v_groups,
    'members_transferred', v_members,
    'open_loans_transferred', v_loans,
    'open_orders_transferred', v_orders
  );
end;
$$;

grant execute on function public.pb_transfer_officer_book(uuid, uuid, text) to authenticated;

-- Optional setup after running the script:
-- 1. Go to Staff & Permissions.
-- 2. Edit the two supervisors and enter Team A / Team B under "Team / supervisor group".
-- 3. Edit each loan officer/officer and enter the matching team name.
-- 4. Use "Transfer officer book" to move David Otieno's book to Griven Laban.
