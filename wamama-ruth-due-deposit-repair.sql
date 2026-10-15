-- Installs the ongoing release fix, then applies only Ruth's overdue instalments.
-- Existing loan amounts, savings and the future loan are preserved.
-- Deposits are reduced by exactly the approved repayments created; release links prevent repeat use.
DO $install_release_fix$
BEGIN


create index if not exists pb_excess_prepayment_release_lookup_idx
  on public.pb_excess_payments (business_id, member_id, payment_date, created_at)
  where status = 'pending'
    and source = 'scheduled_prepayment';

create index if not exists pb_repayments_loan_status_amount_idx
  on public.pb_repayments (loan_id, status)
  include (amount);

create index if not exists pb_loans_business_status_member_idx
  on public.pb_loans (business_id, status, member_id);

drop function if exists public.pb_release_due_prepayments();

create or replace function public.pb_release_due_prepayments(
  p_loan_ids text[] default null,
  p_limit integer default 25
)
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
      and l.start_date is not null
      and l.start_date <= v_today
      and coalesce(l.weekly_installment, 0) > 0
      -- Saved end dates can predate the remaining instalments after edits.
      -- Keep accruing weekly dues through today, capped by total_payable.
      -- A future-only deposit cannot consume one of the limited batch slots.
      -- Select only a loan whose instalment is due and remains unpaid.
      and coalesce((
        select sum(r.amount) from public.pb_repayments r
        where r.loan_id::text = l.id::text
          and r.voided_at is null
          and lower(coalesce(r.status::text, 'approved'))
            not in ('pending','rejected','cancelled','voided')
          and coalesce(r.meeting_date,
            (r.created_at at time zone 'Africa/Nairobi')::date) <= v_today
      ), 0) + 0.01 < least(l.total_payable,
        (floor((v_today
          - l.start_date)::numeric / 7) + 1) * l.weekly_installment)
      and (
        p_loan_ids is null
        or l.member_id::text in (
          select source_loan.member_id::text
          from public.pb_loans source_loan
          where source_loan.business_id::text = v_business_id
            and source_loan.id::text = any(p_loan_ids)
        )
      )
      and exists (
        select 1
        from public.pb_excess_payments ep
        where ep.business_id = v_business_id
          and ep.member_id = l.member_id::text
          and ep.status = 'pending'
          and ep.source = 'scheduled_prepayment'
          and ep.excess_amount > coalesce(ep.released_amount, 0)
          and ep.payment_date < l.start_date +
            (floor((v_today
              - l.start_date)::numeric / 7)::integer * 7)
          and not exists (
            select 1 from public.pb_prepayment_releases existing_release
            where existing_release.prepayment_id = ep.id::text
              and existing_release.loan_id = l.id::text
              and existing_release.due_date = l.start_date +
                (floor((v_today
                  - l.start_date)::numeric / 7)::integer * 7)
          )
          and (
            ep.loan_id = l.id::text
            or not exists (
              select 1
              from public.pb_loans source_loan
              where source_loan.id::text = ep.loan_id
                and lower(coalesce(source_loan.status::text, 'active')) = 'active'
            )
          )
      )
    order by l.start_date, l.created_at, l.id
    limit greatest(1, least(coalesce(p_limit, 25), 100))
    for update
  loop
    select coalesce(sum(r.amount), 0)
      into v_paid
    from public.pb_repayments r
    where r.loan_id::text = loan_row.id::text
      and r.voided_at is null
      and lower(coalesce(r.status::text, 'approved'))
        not in ('pending','rejected','cancelled','voided')
      and coalesce(r.meeting_date,
        (r.created_at at time zone 'Africa/Nairobi')::date) <= v_today;

    if loan_row.start_date is null
       or loan_row.start_date > v_today
       or coalesce(loan_row.weekly_installment, 0) <= 0 then
      continue;
    end if;

    for due_row in
      select gs::date as due_date,
             row_number() over (order by gs)::numeric as instalment_number
      from generate_series(
        loan_row.start_date,
        v_today,
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
        where ep.business_id = v_business_id
          and ep.member_id = loan_row.member_id::text
          and ep.status = 'pending'
          and ep.source = 'scheduled_prepayment'
          and ep.payment_date < due_row.due_date
          and ep.excess_amount > coalesce(ep.released_amount, 0)
          and not exists (
            select 1
            from public.pb_prepayment_releases existing_release
            where existing_release.prepayment_id = ep.id::text
              and existing_release.loan_id = loan_row.id::text
              and existing_release.due_date = due_row.due_date
          )
          and (
            ep.loan_id = loan_row.id::text
            or not exists (
              select 1
              from public.pb_loans source_loan
              where source_loan.id::text = ep.loan_id
                and lower(coalesce(source_loan.status::text, 'active')) = 'active'
            )
          )
        order by case when ep.loan_id = loan_row.id::text then 0 else 1 end,
                 ep.payment_date, ep.created_at, ep.id
        for update
      loop
        exit when v_due <= 0;
        v_available := round(deposit_row.excess_amount - coalesce(deposit_row.released_amount, 0), 2);
        v_release := round(least(v_due, v_available), 2);
        if v_release <= 0 then continue; end if;

        select r.recorded_by
          into v_recorded_by
        from public.pb_repayments r
        where r.id::text = deposit_row.original_repayment_id
        limit 1;

        v_principal := round(
          v_release * case
            when coalesce(loan_row.total_payable, 0) > 0
              then coalesce(loan_row.loan_value, 0) / loan_row.total_payable
            else 1
          end,
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

    if v_paid + 0.01 >= loan_row.total_payable then
      update public.pb_loans
      set status = 'completed'
      where id::text = loan_row.id::text
        and lower(coalesce(status::text, '')) = 'active';
    end if;
  end loop;

  return v_release_count;
end;
$$;

grant execute on function public.pb_release_due_prepayments(text[], integer) to authenticated;
revoke all on function public.pb_release_due_prepayments(text[], integer) from public, anon;


DO $ruth_repair$
declare
  p_loan_ids text[] := array['e33a8eea-bf63-4c51-83b5-8f3c38769038'];
  p_limit integer := 1;
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
  v_business_id := 'b3462eea-1c92-4411-9507-fb6c0b31ba28';
  if nullif(v_business_id, '') is null then
    raise exception 'No active Wamama business session was found.';
  end if;

  for loan_row in
    select l.*
    from public.pb_loans l
    where l.business_id::text = v_business_id
      and l.id::text='e33a8eea-bf63-4c51-83b5-8f3c38769038'
      and l.member_id::text='871ffd6c-c777-40ff-9773-8dbf92ca2ee4'
      and lower(coalesce(l.status::text, 'active')) = 'active'
      and l.start_date is not null
      and l.start_date <= v_today
      and coalesce(l.weekly_installment, 0) > 0
      -- Saved end dates can predate the remaining instalments after edits.
      -- Keep accruing weekly dues through today, capped by total_payable.
      -- A future-only deposit cannot consume one of the limited batch slots.
      -- Select only a loan whose instalment is due and remains unpaid.
      and coalesce((
        select sum(r.amount) from public.pb_repayments r
        where r.loan_id::text = l.id::text
          and r.voided_at is null
          and lower(coalesce(r.status::text, 'approved'))
            not in ('pending','rejected','cancelled','voided')
          and coalesce(r.meeting_date,
            (r.created_at at time zone 'Africa/Nairobi')::date) <= v_today
      ), 0) + 0.01 < least(l.total_payable,
        (floor((v_today
          - l.start_date)::numeric / 7) + 1) * l.weekly_installment)
      and (
        p_loan_ids is null
        or l.member_id::text in (
          select source_loan.member_id::text
          from public.pb_loans source_loan
          where source_loan.business_id::text = v_business_id
            and source_loan.id::text = any(p_loan_ids)
        )
      )
      and exists (
        select 1
        from public.pb_excess_payments ep
        where ep.business_id = v_business_id
          and ep.member_id = l.member_id::text
          and ep.status = 'pending'
          and ep.source = 'scheduled_prepayment'
          and ep.excess_amount > coalesce(ep.released_amount, 0)
          and ep.payment_date < l.start_date +
            (floor((v_today
              - l.start_date)::numeric / 7)::integer * 7)
          and not exists (
            select 1 from public.pb_prepayment_releases existing_release
            where existing_release.prepayment_id = ep.id::text
              and existing_release.loan_id = l.id::text
              and existing_release.due_date = l.start_date +
                (floor((v_today
                  - l.start_date)::numeric / 7)::integer * 7)
          )
          and (
            ep.loan_id = l.id::text
            or not exists (
              select 1
              from public.pb_loans source_loan
              where source_loan.id::text = ep.loan_id
                and lower(coalesce(source_loan.status::text, 'active')) = 'active'
            )
          )
      )
    order by l.start_date, l.created_at, l.id
    limit greatest(1, least(coalesce(p_limit, 25), 100))
    for update
  loop
    select coalesce(sum(r.amount), 0)
      into v_paid
    from public.pb_repayments r
    where r.loan_id::text = loan_row.id::text
      and r.voided_at is null
      and lower(coalesce(r.status::text, 'approved'))
        not in ('pending','rejected','cancelled','voided')
      and coalesce(r.meeting_date,
        (r.created_at at time zone 'Africa/Nairobi')::date) <= v_today;

    if loan_row.start_date is null
       or loan_row.start_date > v_today
       or coalesce(loan_row.weekly_installment, 0) <= 0 then
      continue;
    end if;

    for due_row in
      select gs::date as due_date,
             row_number() over (order by gs)::numeric as instalment_number
      from generate_series(
        loan_row.start_date,
        v_today,
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
        where ep.business_id = v_business_id
          and ep.member_id = loan_row.member_id::text
          and ep.status = 'pending'
          and ep.source = 'scheduled_prepayment'
          and ep.payment_date < due_row.due_date
          and ep.excess_amount > coalesce(ep.released_amount, 0)
          and not exists (
            select 1
            from public.pb_prepayment_releases existing_release
            where existing_release.prepayment_id = ep.id::text
              and existing_release.loan_id = loan_row.id::text
              and existing_release.due_date = due_row.due_date
          )
          and (
            ep.loan_id = loan_row.id::text
            or not exists (
              select 1
              from public.pb_loans source_loan
              where source_loan.id::text = ep.loan_id
                and lower(coalesce(source_loan.status::text, 'active')) = 'active'
            )
          )
        order by case when ep.loan_id = loan_row.id::text then 0 else 1 end,
                 ep.payment_date, ep.created_at, ep.id
        for update
      loop
        exit when v_due <= 0;
        v_available := round(deposit_row.excess_amount - coalesce(deposit_row.released_amount, 0), 2);
        v_release := round(least(v_due, v_available), 2);
        if v_release <= 0 then continue; end if;

        select r.recorded_by
          into v_recorded_by
        from public.pb_repayments r
        where r.id::text = deposit_row.original_repayment_id
        limit 1;

        v_principal := round(
          v_release * case
            when coalesce(loan_row.total_payable, 0) > 0
              then coalesce(loan_row.loan_value, 0) / loan_row.total_payable
            else 1
          end,
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

    if v_paid + 0.01 >= loan_row.total_payable then
      update public.pb_loans
      set status = 'completed'
      where id::text = loan_row.id::text
        and lower(coalesce(status::text, '')) = 'active';
    end if;
  end loop;

  raise notice 'Ruth deposit release records created: %',v_release_count;
end;
$ruth_repair$;
END;
$install_release_fix$;

with context as (select (now() at time zone 'Africa/Nairobi')::date today),
paid as (
 select coalesce(sum(amount),0) amount from public.pb_repayments r cross join context c
 where r.business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28'
 and r.loan_id::text='e33a8eea-bf63-4c51-83b5-8f3c38769038'
 and r.voided_at is null and lower(coalesce(r.status::text,'approved')) not in ('pending','rejected','cancelled','voided')
 and coalesce(r.meeting_date::date,(r.created_at at time zone 'Africa/Nairobi')::date)<=c.today
)
select c.today report_date,l.id loan_id,p.amount approved_paid,
 greatest(0,least(l.total_payable,greatest(0,floor((c.today-l.start_date::date)/7.0)+1)*l.weekly_installment)-p.amount) unpaid_due_today,
 (select coalesce(sum(greatest(0,ep.excess_amount-coalesce(ep.released_amount,0))),0)
 from public.pb_excess_payments ep where ep.business_id::text=l.business_id::text and ep.loan_id::text=l.id::text
 and ep.member_id::text=l.member_id::text and ep.status='pending' and ep.source='scheduled_prepayment') remaining_loan_deposits
from public.pb_loans l cross join context c cross join paid p
where l.id::text='e33a8eea-bf63-4c51-83b5-8f3c38769038' and l.business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28';
