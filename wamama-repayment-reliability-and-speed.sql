-- Wamama Pamoja Enterprise
-- Reliable, permission-aware repayment recording for officers, supervisors,
-- branch management and administrators.
--
-- Safe scope:
--   * Does not update or delete any historical repayment, saving or loan.
--   * Does not recalculate any balance.
--   * Adds one server-side function and supporting indexes only.

begin;

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='pb_repayments' and column_name='updated_at'
  ) then
    execute 'create index if not exists pb_repayments_business_updated_idx on public.pb_repayments (business_id, updated_at desc)';
  end if;
end
$$;

create index if not exists pb_repayments_business_status_created_idx
  on public.pb_repayments (business_id, status, created_at desc);

create index if not exists pb_loans_business_member_status_idx
  on public.pb_loans (business_id, member_id, status);

create or replace function public.pb_record_repayments_batch(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.pb_staff%rowtype;
  v_permission boolean := false;
  v_item jsonb;
  v_loan public.pb_loans%rowtype;
  v_meeting_id public.pb_repayments.meeting_id%type;
  v_saved public.pb_repayments%rowtype;
  v_amount numeric;
  v_interest numeric;
  v_principal numeric;
  v_status text;
  v_rows jsonb := '[]'::jsonb;
  v_failures jsonb := '[]'::jsonb;
begin
  select s.* into v_staff
  from public.pb_staff s
  where s.auth_user_id = auth.uid()
    and lower(coalesce(s.status, 'active')) = 'active'
  limit 1;

  if not found then
    raise exception 'Your active Wamama staff account could not be found. Please sign in again.';
  end if;

  select coalesce(p.can_record_repayments, false)
    into v_permission
  from public.pb_permissions p
  where p.staff_id::text = v_staff.id::text
  limit 1;

  if lower(coalesce(v_staff.role, '')) not in
       ('ceo','admin','branch_manager','supervisor','loan_officer','officer')
     and not coalesce(v_permission, false) then
    raise exception 'Your role does not have permission to record repayments.';
  end if;

  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'No repayment entries were supplied.';
  end if;

  v_status := case
    when lower(coalesce(v_staff.role, '')) in ('ceo','admin','branch_manager') then 'approved'
    else 'pending'
  end;

  for v_item in select value from jsonb_array_elements(p_rows)
  loop
    begin
      v_amount := round(coalesce(nullif(v_item->>'amount','')::numeric, 0), 2);
      if v_amount <= 0 then raise exception 'Repayment amount must be greater than zero.'; end if;

      select l.* into v_loan
      from public.pb_loans l
      where l.id::text = nullif(v_item->>'loan_id','')
        and l.business_id::text = v_staff.business_id::text
        and lower(coalesce(l.status, 'active')) = 'active'
      limit 1;

      if not found then raise exception 'The selected active loan was not found in your business.'; end if;

      v_meeting_id := null;
      if nullif(v_item->>'meeting_id','') is not null then
        select m.id into v_meeting_id
        from public.pb_meetings m
        where m.id::text = v_item->>'meeting_id'
          and m.business_id::text = v_staff.business_id::text
        limit 1;
      end if;

      v_interest := round(
        v_amount * case
          when coalesce(v_loan.total_payable,0) > 0
            then greatest(0,(coalesce(v_loan.total_payable,0)-coalesce(v_loan.loan_value,0))/v_loan.total_payable)
          else 0
        end,
        2
      );
      v_principal := round(v_amount-v_interest,2);

      insert into public.pb_repayments (
        business_id, loan_id, member_id, group_id, meeting_id, meeting_date,
        amount, principal, interest, recorded_by, status
      ) values (
        v_loan.business_id, v_loan.id, v_loan.member_id, v_loan.group_id,
        v_meeting_id,
        coalesce(nullif(v_item->>'meeting_date','')::date,(now() at time zone 'Africa/Nairobi')::date),
        v_amount, v_principal, v_interest, v_staff.id, v_status
      )
      returning * into v_saved;

      v_rows := v_rows || jsonb_build_array(to_jsonb(v_saved));
    exception when others then
      v_failures := v_failures || jsonb_build_array(jsonb_build_object(
        'loan_id',v_item->>'loan_id',
        'member_id',v_item->>'member_id',
        'message',sqlerrm
      ));
    end;
  end loop;

  return jsonb_build_object(
    'ok',jsonb_array_length(v_rows) > 0,
    'saved_count',jsonb_array_length(v_rows),
    'failed_count',jsonb_array_length(v_failures),
    'rows',v_rows,
    'failures',v_failures
  );
end;
$$;

revoke all on function public.pb_record_repayments_batch(jsonb) from public;
grant execute on function public.pb_record_repayments_batch(jsonb) to authenticated;

commit;

select
  'Wamama repayment reliability and browser performance support is ready' as result,
  false as historical_repayments_changed,
  false as loan_balances_changed,
  false as savings_changed;
