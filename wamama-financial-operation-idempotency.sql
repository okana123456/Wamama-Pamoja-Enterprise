-- Wamama Pamoja Enterprise
-- Idempotent financial submissions (meeting savings, meeting repayments,
-- standalone repayments).
--
-- What this does
--   * Adds a nullable client_operation_id (uuid) and client_operation_hash to
--     pb_meetings, pb_savings and pb_repayments.
--   * Enforces one row per (business_id, client_operation_id).
--   * Adds pb_submit_meeting(jsonb): one request records a whole meeting.
--     A retry with the same operation IDs returns the rows already saved and
--     never inserts another saving, receipt or deposit.
--   * Extends pb_record_repayments_batch(jsonb) with the same behaviour when a
--     row carries client_operation_id. Rows without one behave exactly as before
--     so browsers still running the previous release keep working.
--
-- What this does NOT do
--   * It does not update, delete or recalculate any historical record.
--   * It does not remove the repeated-meeting guards installed on 18 Nov 2026;
--     those remain as a second line of defence for older browsers.
--
-- Safe to run more than once. Run the whole file in the Supabase SQL editor.

begin;

alter table public.pb_meetings   add column if not exists client_operation_id uuid;
alter table public.pb_savings    add column if not exists client_operation_id uuid;
alter table public.pb_savings    add column if not exists client_operation_hash text;
alter table public.pb_repayments add column if not exists client_operation_id uuid;
alter table public.pb_repayments add column if not exists client_operation_hash text;

-- Partial unique indexes: historical rows (NULL operation id) are unaffected.
create unique index if not exists pb_meetings_business_operation_uidx
  on public.pb_meetings (business_id, client_operation_id)
  where client_operation_id is not null;
create unique index if not exists pb_savings_business_operation_uidx
  on public.pb_savings (business_id, client_operation_id)
  where client_operation_id is not null;
create unique index if not exists pb_repayments_business_operation_uidx
  on public.pb_repayments (business_id, client_operation_id)
  where client_operation_id is not null;

-- Lookups used by the repeated-meeting guards. (pb_meetings already has
-- idx_pb_meetings_business_group_date in production.)
create index if not exists pb_savings_business_meeting_member_idx
  on public.pb_savings (business_id, meeting_id, member_id);
create index if not exists pb_repayments_business_meeting_loan_idx
  on public.pb_repayments (business_id, meeting_id, loan_id);

-- The 30-second guard predates operation IDs. A row that carries its own
-- operation ID is deduplicated exactly by the unique index above, so two
-- genuinely separate same-amount payments are no longer refused. Rows without
-- an operation ID (older browsers) keep the previous behaviour.
create or replace function public.pb_block_rapid_duplicate_pending_repayment()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if new.client_operation_id is not null then return new; end if;
  if lower(coalesce(new.status, 'pending')) <> 'pending' then return new; end if;
  if exists (
    select 1 from public.pb_repayments r
    where r.business_id::text = new.business_id::text
      and r.member_id::text = new.member_id::text
      and r.loan_id::text = new.loan_id::text
      and coalesce(r.group_id::text, '') = coalesce(new.group_id::text, '')
      and round(coalesce(r.amount, 0)::numeric, 2) = round(coalesce(new.amount, 0)::numeric, 2)
      and coalesce(r.meeting_date, current_date) = coalesce(new.meeting_date, current_date)
      and coalesce(r.recorded_by::text, '') = coalesce(new.recorded_by::text, '')
      and lower(coalesce(r.status, 'pending')) = 'pending'
      and r.created_at >= now() - interval '30 seconds'
  ) then
    raise exception 'This repayment was already submitted. Refresh the approvals list before trying again.';
  end if;
  return new;
end;
$$;
revoke all on function public.pb_block_rapid_duplicate_pending_repayment() from public, anon, authenticated;

-- Financial fingerprint of an operation. Notes are deliberately excluded:
-- they do not change the money recorded.
create or replace function public.pb_operation_hash(
  p_kind text, p_member_id text, p_loan_id text, p_meeting_date date, p_amount numeric)
returns text language sql immutable
set search_path = pg_catalog, public, pg_temp
as $$
  select md5(concat_ws('|', p_kind, coalesce(p_member_id,''), coalesce(p_loan_id,''),
    coalesce(p_meeting_date::text,''), to_char(round(coalesce(p_amount,0),2),'FM999999999990.00')));
$$;

-- Internal: record one repayment operation. Not callable by API users.
create or replace function public.pb_record_repayment_operation(
  p_staff_id text, p_business_id text, p_status text, p_meeting_id text, p_item jsonb)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_op uuid;
  v_loan public.pb_loans%rowtype;
  v_existing public.pb_repayments%rowtype;
  v_saved public.pb_repayments%rowtype;
  v_amount numeric;
  v_interest numeric;
  v_date date;
  v_hash text;
  v_meeting public.pb_meetings%rowtype;
begin
  v_amount := round(coalesce(nullif(p_item->>'amount','')::numeric,0),2);
  if v_amount <= 0 then raise exception 'Repayment amount must be greater than zero.' using errcode='22023'; end if;
  v_date := coalesce(nullif(p_item->>'meeting_date','')::date,(now() at time zone 'Africa/Nairobi')::date);
  v_op := nullif(p_item->>'client_operation_id','')::uuid;

  if v_op is not null then
    v_hash := public.pb_operation_hash('repayment', null, p_item->>'loan_id', v_date, v_amount);
    perform pg_advisory_xact_lock(hashtextextended('wamama-op:'||p_business_id||':'||v_op::text,0));
    select r.* into v_existing from public.pb_repayments r
     where r.business_id::text = p_business_id and r.client_operation_id = v_op limit 1;
    if found then
      if coalesce(v_existing.client_operation_hash,'') <> v_hash then
        raise exception 'OPERATION_MISMATCH: this submission ID was already used for a different repayment.'
          using errcode='23505';
      end if;
      return jsonb_build_object('state','existing','row',to_jsonb(v_existing));
    end if;
  end if;

  select l.* into v_loan from public.pb_loans l
   where l.id::text = nullif(p_item->>'loan_id','')
     and l.business_id::text = p_business_id
     and lower(coalesce(l.status,'active')) = 'active'
   limit 1;
  if not found then raise exception 'The selected active loan was not found in your business.'; end if;

  if p_meeting_id is not null then
    select m.* into v_meeting from public.pb_meetings m
     where m.id::text = p_meeting_id and m.business_id::text = p_business_id limit 1;
    -- Previous behaviour: an unknown meeting is recorded without a meeting link.
    if not found then p_meeting_id := null; end if;
  end if;

  v_interest := round(v_amount * case when coalesce(v_loan.total_payable,0) > 0
    then greatest(0,(coalesce(v_loan.total_payable,0)-coalesce(v_loan.loan_value,0))/v_loan.total_payable)
    else 0 end, 2);

  insert into public.pb_repayments (
    business_id, loan_id, member_id, group_id, meeting_id, meeting_date,
    amount, principal, interest, recorded_by, status, client_operation_id, client_operation_hash)
  values (
    v_loan.business_id, v_loan.id, v_loan.member_id, v_loan.group_id,
    case when p_meeting_id is null then null else v_meeting.id end, v_date,
    v_amount, round(v_amount-v_interest,2), v_interest,
    (select s.id from public.pb_staff s where s.id::text = p_staff_id limit 1),
    p_status, v_op, v_hash)
  returning * into v_saved;
  return jsonb_build_object('state','created','row',to_jsonb(v_saved));
end;
$$;

-- Internal: record one saving operation. Not callable by API users.
create or replace function public.pb_record_saving_operation(
  p_staff_id text, p_business_id text, p_status text, p_meeting_id text, p_item jsonb)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_op uuid;
  v_member public.pb_members%rowtype;
  v_meeting public.pb_meetings%rowtype;
  v_existing public.pb_savings%rowtype;
  v_saved public.pb_savings%rowtype;
  v_amount numeric;
  v_date date;
  v_hash text;
begin
  v_amount := round(coalesce(nullif(p_item->>'amount','')::numeric,0),2);
  if v_amount <= 0 then raise exception 'Savings amount must be greater than zero.' using errcode='22023'; end if;
  v_op := nullif(p_item->>'client_operation_id','')::uuid;
  if v_op is null then raise exception 'A submission ID is required for savings.' using errcode='22023'; end if;

  select m.* into v_meeting from public.pb_meetings m
   where m.id::text = p_meeting_id and m.business_id::text = p_business_id limit 1;
  if not found then raise exception 'The meeting was not found in your business.'; end if;
  v_date := v_meeting.meeting_date;

  v_hash := public.pb_operation_hash('saving', p_item->>'member_id', null, v_date, v_amount);
  perform pg_advisory_xact_lock(hashtextextended('wamama-op:'||p_business_id||':'||v_op::text,0));
  select s.* into v_existing from public.pb_savings s
   where s.business_id::text = p_business_id and s.client_operation_id = v_op limit 1;
  if found then
    if coalesce(v_existing.client_operation_hash,'') <> v_hash then
      raise exception 'OPERATION_MISMATCH: this submission ID was already used for a different saving.'
        using errcode='23505';
    end if;
    return jsonb_build_object('state','existing','row',to_jsonb(v_existing));
  end if;

  select m.* into v_member from public.pb_members m
   where m.id::text = nullif(p_item->>'member_id','') and m.business_id::text = p_business_id limit 1;
  if not found then raise exception 'The member was not found in your business.'; end if;

  insert into public.pb_savings (
    business_id, member_id, group_id, meeting_id, meeting_date, amount,
    recorded_by, notes, status, client_operation_id, client_operation_hash)
  values (
    v_member.business_id, v_member.id, v_meeting.group_id, v_meeting.id, v_date, v_amount,
    (select s.id from public.pb_staff s where s.id::text = p_staff_id limit 1),
    nullif(left(coalesce(p_item->>'notes',''),500),''), p_status, v_op, v_hash)
  returning * into v_saved;
  return jsonb_build_object('state','created','row',to_jsonb(v_saved));
end;
$$;

revoke all on function public.pb_record_repayment_operation(text,text,text,text,jsonb) from public, anon, authenticated;
revoke all on function public.pb_record_saving_operation(text,text,text,text,jsonb) from public, anon, authenticated;

-- One request records a whole meeting. Each saving and repayment is its own
-- operation: a failure of one entry never undoes or repeats the others.
create or replace function public.pb_submit_meeting(p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_staff public.pb_staff%rowtype;
  v_can_record boolean := false;
  v_role text;
  v_status text;
  v_group public.pb_groups%rowtype;
  v_meeting public.pb_meetings%rowtype;
  v_meeting_op uuid;
  v_date date;
  v_item jsonb;
  v_result jsonb;
  v_savings jsonb := '[]'::jsonb;
  v_repayments jsonb := '[]'::jsonb;
  v_meeting_state text := 'existing';
begin
  select s.* into v_staff from public.pb_staff s
   where s.auth_user_id = auth.uid() and lower(coalesce(s.status,'active')) = 'active' limit 1;
  if not found then raise exception 'Your active Wamama staff account could not be found. Please sign in again.'; end if;
  v_role := lower(coalesce(v_staff.role,''));
  select coalesce(p.can_record_repayments,false) into v_can_record
    from public.pb_permissions p where p.staff_id::text = v_staff.id::text limit 1;
  if v_role not in ('ceo','admin','branch_manager','supervisor','loan_officer','officer')
     and not coalesce(v_can_record,false) then
    raise exception 'Your role does not have permission to record meeting collections.';
  end if;
  -- Same approval rule as the previous browser code and pb_record_repayments_batch.
  v_status := case when v_role in ('ceo','admin','branch_manager') then 'approved' else 'pending' end;

  if jsonb_typeof(p_payload) <> 'object' then raise exception 'Invalid meeting submission.'; end if;
  v_meeting_op := nullif(p_payload->>'operation_id','')::uuid;
  v_date := nullif(p_payload->>'meeting_date','')::date;
  if v_meeting_op is null or v_date is null then
    raise exception 'The meeting submission ID and date are required.' using errcode='22023';
  end if;

  select g.* into v_group from public.pb_groups g
   where g.id::text = nullif(p_payload->>'group_id','') and g.business_id::text = v_staff.business_id::text limit 1;
  if not found then raise exception 'The group was not found in your business.'; end if;

  -- One meeting per group and date. Serialise concurrent first submissions.
  perform pg_advisory_xact_lock(hashtextextended(
    'wamama-meeting:'||v_staff.business_id::text||':'||v_group.id::text||':'||v_date::text,0));
  select m.* into v_meeting from public.pb_meetings m
   where m.business_id::text = v_staff.business_id::text
     and m.group_id::text = v_group.id::text and m.meeting_date = v_date
   limit 1;
  if not found then
    insert into public.pb_meetings (business_id, group_id, meeting_date, recorded_by, client_operation_id)
    values (v_group.business_id, v_group.id, v_date, v_staff.id, v_meeting_op)
    returning * into v_meeting;
    v_meeting_state := 'created';
  end if;

  for v_item in select value from jsonb_array_elements(coalesce(p_payload->'savings','[]'::jsonb)) loop
    begin
      v_result := public.pb_record_saving_operation(v_staff.id::text, v_staff.business_id::text,
        v_status, v_meeting.id::text, v_item);
    exception when others then
      v_result := jsonb_build_object('state','failed','code',sqlstate,'message',sqlerrm);
    end;
    v_savings := v_savings || jsonb_build_array(v_result || jsonb_build_object(
      'client_operation_id', v_item->>'client_operation_id', 'member_id', v_item->>'member_id'));
  end loop;

  for v_item in select value from jsonb_array_elements(coalesce(p_payload->'repayments','[]'::jsonb)) loop
    begin
      if nullif(v_item->>'client_operation_id','') is null then
        raise exception 'A submission ID is required for meeting repayments.' using errcode='22023';
      end if;
      v_result := public.pb_record_repayment_operation(v_staff.id::text, v_staff.business_id::text,
        v_status, v_meeting.id::text, v_item || jsonb_build_object('meeting_date', v_date));
    exception when others then
      v_result := jsonb_build_object('state','failed','code',sqlstate,'message',sqlerrm);
    end;
    v_repayments := v_repayments || jsonb_build_array(v_result || jsonb_build_object(
      'client_operation_id', v_item->>'client_operation_id', 'loan_id', v_item->>'loan_id'));
  end loop;

  return jsonb_build_object(
    'version', 1,
    'operation_id', v_meeting_op,
    'meeting', jsonb_build_object('state', v_meeting_state, 'row', to_jsonb(v_meeting)),
    'savings', v_savings,
    'repayments', v_repayments);
end;
$$;

revoke all on function public.pb_submit_meeting(jsonb) from public, anon;
grant execute on function public.pb_submit_meeting(jsonb) to authenticated;

-- Same contract as before, plus idempotency for rows with client_operation_id.
create or replace function public.pb_record_repayments_batch(p_rows jsonb)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_staff public.pb_staff%rowtype;
  v_permission boolean := false;
  v_item jsonb;
  v_status text;
  v_result jsonb;
  v_rows jsonb := '[]'::jsonb;
  v_failures jsonb := '[]'::jsonb;
  v_results jsonb := '[]'::jsonb;
begin
  select s.* into v_staff from public.pb_staff s
   where s.auth_user_id = auth.uid() and lower(coalesce(s.status,'active')) = 'active' limit 1;
  if not found then raise exception 'Your active Wamama staff account could not be found. Please sign in again.'; end if;
  select coalesce(p.can_record_repayments,false) into v_permission
    from public.pb_permissions p where p.staff_id::text = v_staff.id::text limit 1;
  if lower(coalesce(v_staff.role,'')) not in ('ceo','admin','branch_manager','supervisor','loan_officer','officer')
     and not coalesce(v_permission,false) then
    raise exception 'Your role does not have permission to record repayments.';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'No repayment entries were supplied.';
  end if;
  v_status := case when lower(coalesce(v_staff.role,'')) in ('ceo','admin','branch_manager') then 'approved' else 'pending' end;

  for v_item in select value from jsonb_array_elements(p_rows) loop
    begin
      v_result := public.pb_record_repayment_operation(v_staff.id::text, v_staff.business_id::text,
        v_status, nullif(v_item->>'meeting_id',''), v_item);
      v_rows := v_rows || jsonb_build_array(v_result->'row');
    exception when others then
      v_result := jsonb_build_object('state','failed','code',sqlstate,'message',sqlerrm);
      v_failures := v_failures || jsonb_build_array(jsonb_build_object(
        'loan_id',v_item->>'loan_id','member_id',v_item->>'member_id',
        'client_operation_id',v_item->>'client_operation_id','message',sqlerrm));
    end;
    v_results := v_results || jsonb_build_array(v_result || jsonb_build_object(
      'client_operation_id', v_item->>'client_operation_id', 'loan_id', v_item->>'loan_id'));
  end loop;

  return jsonb_build_object(
    'ok', jsonb_array_length(v_rows) > 0,
    'saved_count', jsonb_array_length(v_rows),
    'failed_count', jsonb_array_length(v_failures),
    'rows', v_rows,
    'failures', v_failures,
    'results', v_results);
end;
$$;

revoke all on function public.pb_record_repayments_batch(jsonb) from public, anon;
grant execute on function public.pb_record_repayments_batch(jsonb) to authenticated;

commit;

select 'Idempotent financial submissions installed; historical records unchanged' as result;
