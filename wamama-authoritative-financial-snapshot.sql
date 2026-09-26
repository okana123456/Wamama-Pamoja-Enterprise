-- Run once in the Wamama Supabase SQL editor.
-- Read-only reporting functions. No historical loan/payment amounts are changed.
-- The caller's existing RLS policies remain in force (SECURITY INVOKER).
begin;

do $$ begin
  if to_regclass('public.pb_staff') is null then
    raise exception 'This is not the Wamama database. Open project hqxanetwkvmcfaaewnzl.';
  end if;
  if not exists(select 1 from public.pb_staff where business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28') then
    raise exception 'Wamama business was not found. Open project hqxanetwkvmcfaaewnzl.';
  end if;
end $$;

create index if not exists pb_repayments_financial_delta_idx
  on public.pb_repayments ((business_id::text),(loan_id::text),updated_at);

create or replace function public.pb_financial_snapshot(p_loan_ids text[] default null,p_since timestamptz default null)
returns jsonb language sql stable security invoker set search_path=public
as $$
with context as (
  select s.*, (now() at time zone 'Africa/Nairobi')::date as report_date
  from public.pb_staff s
  where s.auth_user_id=auth.uid() and lower(coalesce(s.status,'active'))='active'
  order by s.id limit 1
), portfolio as (
  select l.*, c.report_date, g.id as current_group_id,
    case when g.id is null then l.officer_id::text else g.officer_id::text end as current_officer_id
  from context c
  join public.pb_loans l on l.business_id::text=c.business_id::text
  left join public.pb_members m on m.id::text=l.member_id::text and m.business_id::text=c.business_id::text
  left join public.pb_groups g on g.id::text=coalesce(m.group_id::text,l.group_id::text) and g.business_id::text=c.business_id::text
  left join public.pb_staff owner on owner.id::text=(case when g.id is null then l.officer_id::text else g.officer_id::text end)
    and owner.business_id::text=c.business_id::text
  where (
      lower(c.role) in ('admin','ceo','branch_manager','inventory_officer','storekeeper')
      or (case when g.id is null then l.officer_id::text else g.officer_id::text end)=c.id::text
      or (lower(c.role)='supervisor' and nullif(lower(trim(c.team_name)),'') is not null
          and lower(trim(owner.team_name))=lower(trim(c.team_name)))
    )
), selected_portfolio as (
  select l.* from portfolio l
  where (p_loan_ids is null or l.id::text=any(p_loan_ids))
    and (p_since is null or l.updated_at>=p_since
      or exists(select 1 from public.pb_members m where m.id::text=l.member_id::text and m.updated_at>=p_since)
      or exists(select 1 from public.pb_groups g where g.id::text=l.current_group_id::text and g.updated_at>=p_since)
      or exists(select 1 from public.pb_repayments changed
        where changed.loan_id::text=l.id::text and changed.business_id::text=l.business_id::text and changed.updated_at>=p_since))
), payments as (
  select r.loan_id::text as loan_id,
    coalesce(sum(r.amount),0)::numeric as paid,
    coalesce(sum(r.principal) filter(where coalesce(r.notes,'') not like 'Auto-deducted%'),0)::numeric as principal_paid,
    coalesce(sum(r.interest) filter(where coalesce(r.notes,'') not like 'Auto-deducted%'),0)::numeric as interest_paid,
    count(*) as repayment_count,max(r.updated_at) as repayment_updated_at
  from public.pb_repayments r
  join selected_portfolio l on l.id::text=r.loan_id::text and l.business_id::text=r.business_id::text
  where r.voided_at is null
    and lower(coalesce(r.status,'approved')) not in ('pending','rejected','cancelled','voided')
    and coalesce(r.meeting_date::date,(r.created_at at time zone 'Africa/Nairobi')::date)<=l.report_date
  group by r.loan_id::text
), balances as (
  select l.*, round(coalesce(p.paid,0),2) as paid,
    round(coalesce(p.principal_paid,0),2) as principal_paid,
    round(coalesce(p.interest_paid,0),2) as interest_paid,
    coalesce(p.repayment_count,0) as repayment_count,p.repayment_updated_at,
    case when l.start_date is null or l.start_date::date>=l.report_date then 0 else
    least(coalesce(l.total_payable,0),
      greatest(0,ceil((l.report_date-l.start_date::date)/7.0))*coalesce(l.weekly_installment,0)) end as overdue_expected,
    case when l.start_date is null or l.start_date::date>l.report_date then 0 else
    least(coalesce(l.total_payable,0),
      greatest(0,floor((l.report_date-l.start_date::date)/7.0)+1)*coalesce(l.weekly_installment,0)) end as due_expected
  from selected_portfolio l left join payments p on p.loan_id=l.id::text
)
select jsonb_build_object(
  'version',1,'authorized',exists(select 1 from context),'complete',p_loan_ids is null and p_since is null,
  'asOfDate',(now() at time zone 'Africa/Nairobi')::date,'checkedAt',now(),
  'visibleLoanIds',coalesce((select jsonb_agg(id::text order by id) from portfolio),'[]'::jsonb),
  'rows',coalesce(jsonb_agg(jsonb_build_object(
    'id',b.id,'status',b.status,'group_id',b.current_group_id,'officer_id',b.current_officer_id,
    'member_id',b.member_id,'start_date',b.start_date,'weekly_installment',b.weekly_installment,
    'loan_value',b.loan_value,'total_payable',b.total_payable,
    'paid',b.paid,'principalPaid',b.principal_paid,'interestPaid',b.interest_paid,
    'repaymentCount',b.repayment_count,'repaymentUpdatedAt',b.repayment_updated_at,
    'principal',coalesce(b.loan_value,0),'totalPayable',coalesce(b.total_payable,0),
    'outstandingPI',round(greatest(0,coalesce(b.total_payable,0)-b.paid),2),
    'outstandingPrincipal',round(greatest(0,coalesce(b.loan_value,0)-b.principal_paid),2),
    'expectedInterest',round(greatest(0,coalesce(b.total_payable,0)-coalesce(b.loan_value,0)),2),
    'amountDue',round(greatest(0,b.due_expected-b.paid),2),
    'arrears',round(greatest(0,b.overdue_expected-b.paid-5),2),
    'nextDueDate',case when coalesce(b.weekly_installment,0)>0 and coalesce(b.total_payable,0)>b.paid and b.start_date is not null
      then b.start_date::date+7*least(
        greatest(0,ceil(b.total_payable/b.weekly_installment)::integer-1),
        greatest(0,ceil((b.report_date-b.start_date::date)/7.0)::integer)) else null end
  ) order by b.id),'[]'::jsonb)
) from balances b;
$$;

revoke all on function public.pb_financial_snapshot(text[],timestamptz) from public, anon;
grant execute on function public.pb_financial_snapshot(text[],timestamptz) to authenticated;

-- Officers do not have direct access to the deposit ledger. Expose only their
-- collection totals, with staff/business/team checks inside the function.
create or replace function public.pb_cash_collection_totals(p_start date,p_end date)
returns jsonb language sql stable security definer set search_path=public
as $$
with context as (
  select s.* from public.pb_staff s where s.auth_user_id=auth.uid()
    and lower(coalesce(s.status,'active'))='active' order by s.id limit 1
), cash as (
  select r.recorded_by::text as recorder_id,r.group_id::text as group_id,
    coalesce(ep.original_payment_amount,r.amount,0)::numeric as cash_received,
    case when lower(coalesce(r.status,'approved'))='rejected' then 0 else coalesce(r.interest,0) end::numeric as interest
  from context c
  join public.pb_repayments r on r.business_id::text=c.business_id::text
  left join public.pb_staff recorder on recorder.id::text=r.recorded_by::text and recorder.business_id::text=c.business_id::text
  left join lateral (
    select e.original_payment_amount,e.status from public.pb_excess_payments e
    where e.original_repayment_id=r.id::text and e.business_id=c.business_id::text and e.source='scheduled_prepayment'
    order by e.created_at,e.id limit 1
  ) ep on true
  where r.voided_at is null and lower(coalesce(r.status,'approved')) not in ('pending','cancelled','voided')
    and (lower(coalesce(r.status,'approved'))<>'rejected' or ep.original_payment_amount is not null)
    and lower(coalesce(ep.status,'pending')) not in ('refunded','cancelled','rejected')
    and coalesce(r.notes,'') not like 'Auto-deducted%'
    and coalesce(r.notes,'') not ilike 'Scheduled prepayment release:%'
    and coalesce(r.meeting_date::date,(r.created_at at time zone 'Africa/Nairobi')::date) between p_start and p_end
    and (
      lower(c.role) in ('admin','ceo','branch_manager','inventory_officer','storekeeper') or r.recorded_by::text=c.id::text
      or (lower(c.role)='supervisor' and nullif(lower(trim(c.team_name)),'') is not null
        and lower(trim(recorder.team_name))=lower(trim(c.team_name)))
    )
), totals as (
  select recorder_id,group_id,round(sum(cash_received),2) as amount,round(sum(interest),2) as interest,count(*) as entries
  from cash group by recorder_id,group_id
)
select jsonb_build_object('authorized',exists(select 1 from context),'start',p_start,'end',p_end,'checkedAt',now(),
  'rows',coalesce(jsonb_agg(jsonb_build_object('recordedBy',recorder_id,'groupId',group_id,'amount',amount,'interest',interest,'entries',entries)),'[]'::jsonb)) from totals;
$$;
revoke all on function public.pb_cash_collection_totals(date,date) from public,anon;
grant execute on function public.pb_cash_collection_totals(date,date) to authenticated;

-- Preserve the deployed trigger/release functions and their permissions.
-- Correct only their repayment sums; voided approved rows must never count.
do $$
declare fn record; definition text;
begin
  for fn in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in
      ('pb_reconcile_paid_loan','pb_capture_repayment_excess','pb_release_due_prepayments')
  loop
    definition:=pg_get_functiondef(fn.oid);
    if definition ~* 'where\s+r[.]loan_id' and definition !~* 'where\s+r[.]voided_at\s+is\s+null\s+and\s+r[.]loan_id' then
      definition:=regexp_replace(definition,'(where[[:space:]]+)(r[.]loan_id)',
        '\1r.voided_at is null and lower(coalesce(r.status::text,''approved'')) <> ''voided'' and \2','gi');
      execute definition;
    end if;
  end loop;
end $$;

commit;
notify pgrst,'reload schema';

-- Installation confirmation; should return true.
select to_regprocedure('public.pb_financial_snapshot(text[],timestamp with time zone)') is not null as financial_snapshot_ready,
  to_regprocedure('public.pb_cash_collection_totals(date,date)') is not null as cash_collection_totals_ready;
