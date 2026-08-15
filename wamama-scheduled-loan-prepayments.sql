-- Wamama Pamoja Enterprise
-- Scheduled loan deposit / prepayment ledger.
-- Run this complete file once in the Wamama Supabase SQL Editor.
--
-- Business rule:
-- 1. A payment covers arrears and instalments due up to the payment date.
-- 2. Any amount paid ahead of that date remains in the loan prepayment account.
-- 3. The available prepayment is released automatically as future weekly instalments fall due.
-- 4. Ordinary member savings are never changed by this setup.
-- 5. Existing historical prepayment rows are not automatically released or rewritten.
-- 6. pb_loans.start_date is the FIRST repayment due date, not the disbursement date.

begin;

alter table public.pb_excess_payments
  add column if not exists released_amount numeric(14,2) not null default 0,
  add column if not exists last_released_at timestamptz;

alter table public.pb_excess_payments
  drop constraint if exists pb_excess_payments_released_amount_check;
alter table public.pb_excess_payments
  add constraint pb_excess_payments_released_amount_check
  check (released_amount >= 0 and released_amount <= excess_amount);

create table if not exists public.pb_prepayment_releases (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  prepayment_id text not null,
  loan_id text not null,
  member_id text not null,
  due_date date not null,
  amount numeric(14,2) not null check (amount > 0),
  repayment_id text,
  created_at timestamptz not null default now(),
  unique (prepayment_id, due_date)
);

create index if not exists pb_prepayment_releases_business_loan_idx
  on public.pb_prepayment_releases (business_id, loan_id, due_date);

alter table public.pb_prepayment_releases enable row level security;

drop policy if exists pb_prepayment_releases_select on public.pb_prepayment_releases;
create policy pb_prepayment_releases_select
on public.pb_prepayment_releases
for select to authenticated
using (
  business_id = public.pb_current_business_id_text()
  and public.pb_can_manage_excess_payments()
);

grant select on public.pb_prepayment_releases to authenticated;

create or replace function public.pb_capture_repayment_excess()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  loan_row record;
  payment_day date;
  already_applied numeric := 0;
  expected_by_payment_day numeric := 0;
  due_room numeric := 0;
  remaining_total numeric := 0;
  applied numeric := 0;
  advance_amount numeric := 0;
  principal_share numeric := 1;
  existing_excess_status text;
begin
  if lower(coalesce(new.status, 'approved')) in ('pending','rejected','cancelled') then
    return new;
  end if;

  -- Scheduled releases are already allocated amounts and must not be split again.
  if coalesce(new.notes, '') like 'Scheduled prepayment release:%' then
    return new;
  end if;

  select l.id, l.business_id, l.member_id, l.group_id, l.total_payable,
         l.weekly_installment, l.start_date, l.expected_end_date
    into loan_row
  from public.pb_loans l
  where l.id::text = new.loan_id::text
  for update;

  if not found or coalesce(loan_row.total_payable, 0) <= 0 then
    return new;
  end if;

  payment_day := coalesce(
    new.meeting_date,
    (new.created_at at time zone 'Africa/Nairobi')::date,
    (now() at time zone 'Africa/Nairobi')::date
  );

  select coalesce(sum(r.amount), 0)
    into already_applied
  from public.pb_repayments r
  where r.loan_id::text = new.loan_id::text
    and r.id::text <> new.id::text
    and lower(coalesce(r.status, 'approved')) not in ('pending','rejected','cancelled');

  -- start_date is already the first repayment due date. On that date one
  -- instalment is due; every seven days after it adds another instalment.
  expected_by_payment_day := case
    when loan_row.start_date is null or payment_day < loan_row.start_date then 0
    when coalesce(loan_row.weekly_installment, 0) <= 0 then loan_row.total_payable
    else least(
      loan_row.total_payable,
      (floor((payment_day - loan_row.start_date)::numeric / 7) + 1)
        * loan_row.weekly_installment
    )
  end;

  due_room := greatest(0, expected_by_payment_day - already_applied);
  remaining_total := greatest(0, loan_row.total_payable - already_applied);
  if coalesce(new.amount, 0) > remaining_total + 0.01 then
    raise exception 'Payment of KES % exceeds the unpaid loan balance of KES %. Record only the unpaid balance.',
      round(new.amount, 2), round(remaining_total, 2);
  end if;
  applied := round(greatest(0, least(coalesce(new.amount, 0), due_room, remaining_total)), 2);
  advance_amount := round(greatest(0, coalesce(new.amount, 0) - applied), 2);

  select ep.status into existing_excess_status
  from public.pb_excess_payments ep
  where ep.original_repayment_id = new.id::text
  limit 1;

  if existing_excess_status is not null and existing_excess_status <> 'pending' then
    raise exception 'This repayment already has a resolved loan prepayment record and cannot be edited.';
  end if;

  if advance_amount <= 0 then
    delete from public.pb_excess_payments
    where original_repayment_id = new.id::text
      and status = 'pending'
      and coalesce(released_amount, 0) = 0;
    return new;
  end if;

  insert into public.pb_excess_payments (
    business_id, member_id, group_id, loan_id, original_repayment_id,
    payment_date, original_payment_amount, amount_applied_to_loan,
    excess_amount, released_amount, status, source, notes
  ) values (
    loan_row.business_id::text,
    loan_row.member_id::text,
    loan_row.group_id::text,
    loan_row.id::text,
    new.id::text,
    payment_day,
    new.amount,
    applied,
    advance_amount,
    0,
    'pending',
    'scheduled_prepayment',
    'Advance payment held and released only as future weekly instalments become due.'
  )
  on conflict (original_repayment_id) where original_repayment_id is not null do update
  set payment_date = excluded.payment_date,
      original_payment_amount = excluded.original_payment_amount,
      amount_applied_to_loan = excluded.amount_applied_to_loan,
      excess_amount = excluded.excess_amount,
      source = excluded.source,
      notes = excluded.notes,
      updated_at = now()
  where public.pb_excess_payments.status = 'pending'
    and coalesce(public.pb_excess_payments.released_amount, 0) = 0;

  principal_share := case
    when coalesce(new.amount, 0) > 0 then coalesce(new.principal, 0) / new.amount
    else 1
  end;

  if applied <= 0 then
    -- The source row remains excluded from loan totals while the full amount is
    -- safely represented by pb_excess_payments. The application labels this as
    -- "Moved to loan deposit", not as a failed collection.
    new.status := 'rejected';
    new.edit_notes := concat_ws(' | ', nullif(new.edit_notes, ''),
      'Full amount held in loan prepayment account until scheduled instalments become due.');
    return new;
  end if;

  new.amount := applied;
  new.principal := round(applied * principal_share, 2);
  new.interest := round(applied - new.principal, 2);
  new.edit_notes := concat_ws(' | ', nullif(new.edit_notes, ''),
    'KES ' || advance_amount || ' held in loan prepayment account for future instalments.');
  return new;
end;
$$;

drop trigger if exists pb_capture_repayment_excess_trigger on public.pb_repayments;
create trigger pb_capture_repayment_excess_trigger
before insert or update of amount, status
on public.pb_repayments
for each row
execute function public.pb_capture_repayment_excess();

create or replace function public.pb_release_due_prepayments()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id text;
  v_today date := (now() at time zone 'Africa/Nairobi')::date;
  loan_row record;
  deposit_row record;
  due_row record;
  v_expected numeric;
  v_paid numeric;
  v_due numeric;
  v_available numeric;
  v_release numeric;
  v_principal numeric;
  v_repayment_id text;
  v_recorded_by public.pb_repayments.recorded_by%type;
  v_release_count integer := 0;
begin
  v_business_id := public.pb_current_business_id_text();
  if nullif(v_business_id, '') is null then
    raise exception 'No active Wamama business session was found.';
  end if;

  for loan_row in
    select l.*
    from public.pb_loans l
    where l.business_id::text = v_business_id
      and lower(coalesce(l.status::text, 'active')) = 'active'
      and exists (
        select 1 from public.pb_excess_payments ep
        where ep.loan_id = l.id::text
          and ep.business_id = v_business_id
          and ep.status = 'pending'
          and ep.source = 'scheduled_prepayment'
          and ep.excess_amount > coalesce(ep.released_amount, 0)
      )
    for update
  loop
    select coalesce(sum(r.amount), 0)
      into v_paid
    from public.pb_repayments r
    where r.loan_id::text = loan_row.id::text
      and lower(coalesce(r.status, 'approved')) not in ('pending','rejected','cancelled');

    -- Process each due date separately so an offline gap still produces a clear
    -- weekly audit trail instead of one combined release.
    for due_row in
      select gs::date as due_date,
             row_number() over (order by gs)::numeric as instalment_number
      from generate_series(
        loan_row.start_date,
        least(v_today, coalesce(loan_row.expected_end_date, v_today)),
        interval '7 days'
      ) gs
      order by gs
    loop
      v_expected := least(
        loan_row.total_payable,
        due_row.instalment_number * loan_row.weekly_installment
      );
      v_due := round(greatest(0, v_expected - v_paid), 2);
      if v_due <= 0 then continue; end if;

      for deposit_row in
        select ep.*
        from public.pb_excess_payments ep
        where ep.loan_id = loan_row.id::text
          and ep.business_id = v_business_id
          and ep.status = 'pending'
          and ep.source = 'scheduled_prepayment'
          and ep.payment_date < due_row.due_date
          and ep.excess_amount > coalesce(ep.released_amount, 0)
        order by ep.payment_date, ep.created_at, ep.id
        for update
      loop
        exit when v_due <= 0;
        v_available := round(deposit_row.excess_amount - coalesce(deposit_row.released_amount, 0), 2);
        v_release := round(least(v_due, v_available), 2);
        if v_release <= 0 then continue; end if;

        select r.recorded_by into v_recorded_by
        from public.pb_repayments r
        where r.id::text = deposit_row.original_repayment_id
        limit 1;

        v_principal := round(
          v_release * case when coalesce(loan_row.total_payable, 0) > 0
            then coalesce(loan_row.loan_value, 0) / loan_row.total_payable else 1 end,
          2
        );

        insert into public.pb_repayments (
          business_id, loan_id, member_id, group_id, meeting_date, amount,
          principal, interest, recorded_by, status, notes
        ) values (
          loan_row.business_id, loan_row.id, loan_row.member_id, loan_row.group_id,
          due_row.due_date, v_release, v_principal, round(v_release - v_principal, 2),
          v_recorded_by, 'approved',
          'Scheduled prepayment release: ' || deposit_row.id::text
        ) returning id::text into v_repayment_id;

        insert into public.pb_prepayment_releases (
          business_id, prepayment_id, loan_id, member_id, due_date, amount, repayment_id
        ) values (
          v_business_id, deposit_row.id::text, loan_row.id::text,
          loan_row.member_id::text, due_row.due_date, v_release, v_repayment_id
        );

        update public.pb_excess_payments
        set released_amount = round(coalesce(released_amount, 0) + v_release, 2),
            last_released_at = now(),
            status = case
              when round(coalesce(released_amount, 0) + v_release, 2) + 0.005 >= excess_amount
                then 'applied_to_loan'
              else 'pending'
            end,
            resolution_reference = case
              when round(coalesce(released_amount, 0) + v_release, 2) + 0.005 >= excess_amount
                then 'Scheduled releases completed'
              else resolution_reference
            end,
            resolved_at = case
              when round(coalesce(released_amount, 0) + v_release, 2) + 0.005 >= excess_amount
                then now()
              else resolved_at
            end,
            updated_at = now()
        where id = deposit_row.id;

        v_due := round(v_due - v_release, 2);
        v_paid := round(v_paid + v_release, 2);
        v_release_count := v_release_count + 1;
      end loop;
    end loop;

    if v_paid + 0.01 >= loan_row.total_payable
       and not exists (
         select 1 from public.pb_excess_payments ep
         where ep.loan_id = loan_row.id::text
           and ep.status = 'pending'
           and ep.source = 'scheduled_prepayment'
           and ep.excess_amount > coalesce(ep.released_amount, 0)
       ) then
      update public.pb_loans
      set status = 'completed'
      where id::text = loan_row.id::text
        and lower(coalesce(status::text, '')) = 'active';
    end if;
  end loop;

  return v_release_count;
end;
$$;

grant execute on function public.pb_release_due_prepayments() to authenticated;
revoke all on function public.pb_release_due_prepayments() from public, anon;

-- Fully paid loans with an unreleased scheduled prepayment remain active until
-- their scheduled instalments have been released. Other fully paid loans close normally.
create or replace function public.pb_reconcile_paid_loan(p_loan_id text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total_payable numeric := 0;
  v_total_paid numeric := 0;
  v_status text;
  v_has_unreleased_prepayment boolean := false;
  v_closed boolean := false;
begin
  if nullif(trim(p_loan_id), '') is null then return false; end if;

  select coalesce(l.total_payable, 0), lower(coalesce(l.status::text, ''))
    into v_total_payable, v_status
  from public.pb_loans l
  where l.id::text = p_loan_id
  for update;

  if not found or v_status <> 'active' or v_total_payable <= 0 then return false; end if;

  select coalesce(sum(coalesce(r.amount, 0)), 0)
    into v_total_paid
  from public.pb_repayments r
  where r.loan_id::text = p_loan_id
    and lower(coalesce(r.status::text, 'approved')) not in ('pending','rejected','cancelled');

  select exists (
    select 1 from public.pb_excess_payments ep
    where ep.loan_id = p_loan_id
      and ep.status = 'pending'
      and ep.source = 'scheduled_prepayment'
      and ep.excess_amount > coalesce(ep.released_amount, 0)
  ) into v_has_unreleased_prepayment;

  if v_total_paid + 0.01 >= v_total_payable and not v_has_unreleased_prepayment then
    update public.pb_loans
    set status = 'completed'
    where id::text = p_loan_id and lower(coalesce(status::text, '')) = 'active';
    v_closed := found;
  end if;
  return v_closed;
end;
$$;

commit;

select
  'Wamama approved-payment allocation and scheduled loan prepayments are ready' as result,
  count(*) filter (where source = 'scheduled_prepayment' and status = 'pending') as new_scheduled_prepayments,
  count(*) filter (where source <> 'scheduled_prepayment' or source is null) as historical_rows_unchanged,
  false as ordinary_savings_changed
from public.pb_excess_payments;
