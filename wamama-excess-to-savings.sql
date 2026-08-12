-- Wamama Pamoja Enterprise
-- Remove the operational excess queue by moving genuine loan overpayments
-- into the affected member's existing savings account.
-- Existing repayment history is preserved and every transfer is auditable.

begin;

create or replace function public.pb_capture_repayment_excess()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  loan_row record;
  already_applied numeric;
  remaining numeric;
  applied numeric;
  excess numeric;
  principal_share numeric;
  transfer_note text;
  payment_day date;
begin
  if lower(coalesce(new.status, 'approved')) in ('pending','rejected','cancelled') then
    return new;
  end if;

  select l.id, l.business_id, l.member_id, l.group_id, l.total_payable
  into loan_row
  from public.pb_loans l
  where l.id::text = new.loan_id::text
  for update;

  if not found or coalesce(loan_row.total_payable, 0) <= 0 then
    return new;
  end if;

  if exists (
    select 1 from public.pb_excess_payments ep
    where ep.original_repayment_id = new.id::text
      and ep.status = 'transferred_to_savings'
  ) then
    raise exception 'This repayment already transferred an overpayment to savings and cannot be edited.';
  end if;

  select coalesce(sum(r.amount), 0)
  into already_applied
  from public.pb_repayments r
  where r.loan_id::text = new.loan_id::text
    and r.id::text <> new.id::text
    and lower(coalesce(r.status, 'approved')) not in ('pending','rejected','cancelled');

  remaining := greatest(0, loan_row.total_payable - already_applied);
  applied := greatest(0, least(coalesce(new.amount, 0), remaining));
  excess := greatest(0, coalesce(new.amount, 0) - applied);
  payment_day := coalesce(
    new.meeting_date,
    (new.created_at at time zone 'Africa/Nairobi')::date,
    (now() at time zone 'Africa/Nairobi')::date
  );
  transfer_note := 'Loan overpayment transferred to savings; repayment ' || new.id::text;

  if excess <= 0 then
    return new;
  end if;

  -- One linked savings entry is maintained for this repayment. This makes the
  -- trigger safe if the same approved repayment is processed more than once.
  update public.pb_savings s
  set amount = excess,
      meeting_date = payment_day,
      notes = transfer_note,
      status = 'approved'
  where s.business_id::text = loan_row.business_id::text
    and s.member_id::text = loan_row.member_id::text
    and s.notes = transfer_note;

  if not found then
    insert into public.pb_savings (
      business_id, member_id, group_id, meeting_date, amount,
      recorded_by, notes, status
    ) values (
      loan_row.business_id, loan_row.member_id, loan_row.group_id,
      payment_day, excess, new.recorded_by, transfer_note, 'approved'
    );
  end if;

  insert into public.pb_excess_payments (
    business_id, member_id, group_id, loan_id, original_repayment_id,
    payment_date, original_payment_amount, amount_applied_to_loan,
    excess_amount, status, source, notes, resolution_reference,
    resolved_at, resolved_by
  ) values (
    loan_row.business_id::text, loan_row.member_id::text,
    loan_row.group_id::text, loan_row.id::text, new.id::text,
    payment_day, new.amount, applied, excess, 'transferred_to_savings',
    'repayment', transfer_note, new.id::text, now(), new.recorded_by::text
  )
  on conflict (original_repayment_id) where original_repayment_id is not null do update
  set payment_date = excluded.payment_date,
      original_payment_amount = excluded.original_payment_amount,
      amount_applied_to_loan = excluded.amount_applied_to_loan,
      excess_amount = excluded.excess_amount,
      status = 'transferred_to_savings',
      notes = excluded.notes,
      resolution_reference = excluded.resolution_reference,
      resolved_at = excluded.resolved_at,
      resolved_by = excluded.resolved_by,
      updated_at = now();

  if applied <= 0 then
    new.status := 'rejected';
    new.edit_notes := concat_ws(' | ', nullif(new.edit_notes, ''),
      'Loan already cleared; full amount of KES ' || round(excess,2) || ' added to savings.');
    return new;
  end if;

  principal_share := case
    when coalesce(new.amount, 0) > 0 then coalesce(new.principal, 0) / new.amount
    else 1
  end;
  new.amount := round(applied, 2);
  new.principal := round(applied * principal_share, 2);
  new.interest := round(applied - new.principal, 2);
  new.edit_notes := concat_ws(' | ', nullif(new.edit_notes, ''),
    'KES ' || round(excess,2) || ' above the remaining loan balance added to savings.');
  return new;
end;
$$;

create or replace function public.pb_protect_excess_source_repayment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1 from public.pb_excess_payments ep
    where ep.original_repayment_id = old.id::text
  ) then
    raise exception 'This repayment has a protected savings-transfer audit record and cannot be deleted.';
  end if;
  return old;
end;
$$;

-- Resolve only the still-pending historical queue. No repayment is changed.
-- The unique audit note makes this migration safe to run again.
do $$
declare
  ex record;
  staff_id public.pb_staff.id%type;
  source_recorder public.pb_repayments.recorded_by%type;
  transfer_note text;
begin
  for ex in
    select ep.*, m.business_id as member_business_id,
           m.id as native_member_id, m.group_id as native_group_id
    from public.pb_excess_payments ep
    join public.pb_members m on m.id::text = ep.member_id
    where ep.status = 'pending'
    order by ep.created_at
    for update of ep
  loop
    select r.recorded_by into source_recorder
    from public.pb_repayments r
    where r.id::text = ex.original_repayment_id
    limit 1;

    if source_recorder is null then
      select s.id into staff_id
      from public.pb_staff s
      where s.business_id::text = ex.business_id
        and lower(coalesce(s.status,'active')) = 'active'
      order by case when lower(coalesce(s.role,'')) in ('admin','ceo') then 0 else 1 end,
               s.created_at
      limit 1;
      source_recorder := staff_id;
    end if;

    if source_recorder is null then
      raise exception 'No active staff account found for business %', ex.business_id;
    end if;

    transfer_note := 'Historical loan overpayment transferred to savings; excess record ' || ex.id::text;

    if not exists (
      select 1 from public.pb_savings s
      where s.business_id::text = ex.business_id
        and s.member_id::text = ex.member_id
        and s.notes = transfer_note
    ) then
      insert into public.pb_savings (
        business_id, member_id, group_id, meeting_date, amount,
        recorded_by, notes, status
      ) values (
        ex.member_business_id, ex.native_member_id, ex.native_group_id,
        ex.payment_date, ex.excess_amount, source_recorder,
        transfer_note, 'approved'
      );
    end if;

    update public.pb_excess_payments
    set status = 'transferred_to_savings',
        resolved_at = now(),
        resolved_by = source_recorder::text,
        resolution_reference = ex.id::text,
        notes = concat_ws(' | ', notes, transfer_note),
        updated_at = now()
    where id = ex.id;
  end loop;
end;
$$;

commit;

select
  'Wamama excess payments now transfer to client savings' as result,
  count(*) filter (where status = 'pending') as pending_excess_rows,
  count(*) filter (where status = 'transferred_to_savings') as transferred_audit_rows,
  false as repayment_history_changed
from public.pb_excess_payments;
