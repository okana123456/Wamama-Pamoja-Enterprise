-- Wamama shared scheduled-deposit allocation. Run this ENTIRE file in SQL Editor.
-- Applies only verified scheduled loan deposits, never savings or pre-loan product deposits.
-- Current due amounts only; future instalments stay in deposits. Original cash receipts are preserved.
DO $install_shared_deposits$
declare constraint_row record; target_loans text[]; target_members integer; job_id bigint;
begin
 if not exists(select 1 from public.pb_staff where business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28') then
   raise exception 'Wamama business not found. No changes made.';
 end if;
 create schema if not exists wamama_deposit_private;
 revoke all on schema wamama_deposit_private from public,anon,authenticated;
 create table if not exists wamama_deposit_private.setup_backup(
   name text primary key,definition text,saved_at timestamptz default now());
 alter table wamama_deposit_private.setup_backup enable row level security;
 revoke all on wamama_deposit_private.setup_backup from public,anon,authenticated;
 insert into wamama_deposit_private.setup_backup(name,definition)
 values('release_function_before_shared_pool',pg_get_functiondef('public.pb_release_due_prepayments(text[],integer)'::regprocedure))
 on conflict(name) do nothing;
 alter table public.pb_prepayment_releases add column if not exists allocation_offset numeric(14,2) not null default 0;
 -- An allocation can be topped up after another receipt/adjustment on the same due date.
 -- The source's already-released balance identifies each distinct allocation.
 for constraint_row in
   select conname from pg_constraint con
   where con.conrelid='public.pb_prepayment_releases'::regclass and con.contype='u'
   and (select array_agg(a.attname::text order by k.ordinality)
     from unnest(con.conkey) with ordinality k(attnum,ordinality)
     join pg_attribute a on a.attrelid=con.conrelid and a.attnum=k.attnum)
       in (array['prepayment_id','loan_id','due_date'],array['prepayment_id','due_date'])
 loop execute format('alter table public.pb_prepayment_releases drop constraint %I',constraint_row.conname); end loop;
 drop index if exists public.pb_prepayment_releases_deposit_loan_due_uidx;
 create unique index if not exists pb_prepayment_release_allocation_uidx
   on public.pb_prepayment_releases(prepayment_id,loan_id,due_date,allocation_offset);
 create index if not exists pb_repayment_deposit_source_lookup_idx
   on public.pb_repayments((id::text),(business_id::text),(member_id::text));
create or replace function wamama_deposit_private.release_due(
  p_business_id text,
  p_loan_ids text[] default null,
  p_limit integer default 25
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
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
  v_business_id := p_business_id;
  if nullif(v_business_id, '') is null then
    raise exception 'No active Wamama business session was found.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('wamama-deposits:'||v_business_id,0));

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
        where r.loan_id::text = l.id::text and r.business_id::text=v_business_id
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
          and exists(select 1 from public.pb_repayments source_payment
            where source_payment.id::text=ep.original_repayment_id
            and source_payment.business_id::text=ep.business_id::text
            and source_payment.member_id::text=ep.member_id::text
            and source_payment.voided_at is null
            and coalesce(source_payment.meeting_date,(source_payment.created_at at time zone 'Africa/Nairobi')::date)<=v_today
            and lower(coalesce(source_payment.status::text,'approved')) not in ('pending','cancelled','voided')
            and (lower(coalesce(source_payment.status::text,'approved'))<>'rejected'
              or coalesce((to_jsonb(ep)->>'original_payment_amount')::numeric,0)>0)
            and coalesce(source_payment.notes,'') not like 'Auto-deducted%'
            and coalesce(source_payment.notes,'') not ilike 'Scheduled prepayment release:%')
          and round(coalesce(ep.released_amount,0),2)>=round(coalesce((
            select sum(used.amount) from public.pb_prepayment_releases used
            where used.prepayment_id=ep.id::text and used.business_id=ep.business_id),0),2)
          and ep.excess_amount > coalesce(ep.released_amount, 0)
          and ep.payment_date <= v_today
      )
    order by l.start_date, l.created_at, l.id
    limit greatest(1, least(coalesce(p_limit, 25), 100))
    for update
  loop
    select coalesce(sum(r.amount), 0)
      into v_paid
    from public.pb_repayments r
    where r.loan_id::text = loan_row.id::text and r.business_id::text=v_business_id
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
          and exists(select 1 from public.pb_repayments source_payment
            where source_payment.id::text=ep.original_repayment_id
            and source_payment.business_id::text=ep.business_id::text
            and source_payment.member_id::text=ep.member_id::text
            and source_payment.voided_at is null
            and coalesce(source_payment.meeting_date,(source_payment.created_at at time zone 'Africa/Nairobi')::date)<=v_today
            and lower(coalesce(source_payment.status::text,'approved')) not in ('pending','cancelled','voided')
            and (lower(coalesce(source_payment.status::text,'approved'))<>'rejected'
              or coalesce((to_jsonb(ep)->>'original_payment_amount')::numeric,0)>0)
            and coalesce(source_payment.notes,'') not like 'Auto-deducted%'
            and coalesce(source_payment.notes,'') not ilike 'Scheduled prepayment release:%')
          and round(coalesce(ep.released_amount,0),2)>=round(coalesce((
            select sum(used.amount) from public.pb_prepayment_releases used
            where used.prepayment_id=ep.id::text and used.business_id=ep.business_id),0),2)
          and ep.payment_date <= v_today
          and ep.excess_amount > coalesce(ep.released_amount, 0)
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
          greatest(due_row.due_date,deposit_row.payment_date), v_release, v_principal, round(v_release - v_principal, 2),
          v_recorded_by, 'approved',
          'Scheduled prepayment release: ' || deposit_row.id::text
        ) returning id::text into v_repayment_id;

        insert into public.pb_prepayment_releases (
          business_id, prepayment_id, loan_id, member_id, due_date, amount, repayment_id, allocation_offset
        ) values (
          v_business_id, deposit_row.id::text, loan_row.id::text,
          loan_row.member_id::text, due_row.due_date, v_release, v_repayment_id, coalesce(deposit_row.released_amount,0)
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

revoke all on function wamama_deposit_private.release_due(text,text[],integer) from public,anon,authenticated;
create or replace function public.pb_release_due_prepayments(p_loan_ids text[] default null,p_limit integer default 25)
returns integer language plpgsql security definer set search_path=pg_catalog,public,pg_temp
as $rpc$
declare business_id text;
begin
 select s.business_id::text into business_id from public.pb_staff s
 where s.auth_user_id=auth.uid() and lower(coalesce(s.status,'active'))='active' order by s.id limit 1;
 if business_id is null then raise exception 'An active Wamama staff session is required.'; end if;
 return wamama_deposit_private.release_due(business_id,p_loan_ids,p_limit);
end;
$rpc$;
revoke all on function public.pb_release_due_prepayments(text[],integer) from public,anon;
grant execute on function public.pb_release_due_prepayments(text[],integer) to authenticated;
-- HOSTED_CRON_EXTENSION
create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('wamama-due-loan-deposits','*/5 * * * *',
 'select wamama_deposit_private.release_due(''b3462eea-1c92-4411-9507-fb6c0b31ba28'',null,100);') into job_id;
update cron.job set active=true where jobid=job_id;
-- Catch up Peres first, then other eligible clients. The job continues subsequent batches.
select coalesce(array_agg(l.id::text),array[]::text[]) into target_loans
from public.pb_loans l join public.pb_members m on m.id::text=l.member_id::text and m.business_id::text=l.business_id::text
join public.pb_groups g on g.id::text=coalesce(m.group_id::text,l.group_id::text) and g.business_id::text=l.business_id::text
where l.business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28' and lower(m.full_name) like '%peres%akong%' and g.name ilike '%mumbo%';
if cardinality(target_loans)>0 then perform wamama_deposit_private.release_due('b3462eea-1c92-4411-9507-fb6c0b31ba28',target_loans,100); end if;
perform wamama_deposit_private.release_due('b3462eea-1c92-4411-9507-fb6c0b31ba28',null,25);
end;
$install_shared_deposits$;

with params as(select (now() at time zone 'Africa/Nairobi')::date today),paid as(
 select r.loan_id::text loan_id,sum(r.amount) amount from public.pb_repayments r cross join params p
 where r.business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28' and r.voided_at is null
 and lower(coalesce(r.status::text,'approved')) not in ('pending','rejected','cancelled','voided')
 and coalesce(r.meeting_date::date,(r.created_at at time zone 'Africa/Nairobi')::date)<=p.today group by r.loan_id::text
)
select p.today report_date,m.full_name member,l.id loan_id,l.asset_name,l.total_payable,coalesce(pay.amount,0) approved_paid,
 greatest(0,l.total_payable-coalesce(pay.amount,0)) remaining_loan_balance,
 greatest(0,least(l.total_payable,greatest(0,ceil((p.today-l.start_date::date)/7.0))*l.weekly_installment)-coalesce(pay.amount,0)-5) arrears,
 (select coalesce(sum(ep.excess_amount-coalesce(ep.released_amount,0)),0) from public.pb_excess_payments ep
 where ep.business_id::text=l.business_id::text and ep.member_id::text=m.id::text and ep.status='pending' and ep.source='scheduled_prepayment') remaining_shared_scheduled_deposits,
 exists(select 1 from cron.job where jobname='wamama-due-loan-deposits' and active) automatic_job_active
from public.pb_loans l join public.pb_members m on m.id::text=l.member_id::text and m.business_id::text=l.business_id::text
left join paid pay on pay.loan_id=l.id::text cross join params p
where l.business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28' and lower(m.full_name) like '%peres%akong%'
order by l.start_date,l.id;
