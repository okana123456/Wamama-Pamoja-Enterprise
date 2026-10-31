-- READ ONLY: Nancy's loan/deposit classification and automatic-job health.
-- Run the whole file in the Wamama Supabase SQL Editor and copy the result row.
with params as (
 select 'b3462eea-1c92-4411-9507-fb6c0b31ba28'::text business_id,
 (now() at time zone 'Africa/Nairobi')::date report_date
), clients as (
 select m.* from public.pb_members m cross join params p
 where m.business_id::text=p.business_id
 and lower(m.full_name) like '%nancy%atieno%ochar%'
), deposits as (
 select ep.*,to_jsonb(source_payment) receipt,
 coalesce((select sum(used.amount) from public.pb_prepayment_releases used
 where used.prepayment_id::text=ep.id::text and used.business_id::text=ep.business_id::text),0) recorded_releases
 from public.pb_excess_payments ep join clients m on m.id::text=ep.member_id::text and m.business_id::text=ep.business_id::text
 left join public.pb_repayments source_payment on source_payment.id::text=ep.original_repayment_id::text
 and source_payment.business_id::text=ep.business_id::text and source_payment.member_id::text=ep.member_id::text
), loans as (
 select l.*,coalesce((select sum(r.amount) from public.pb_repayments r cross join params p
 where r.loan_id::text=l.id::text and r.business_id::text=l.business_id::text
 and r.voided_at is null and lower(coalesce(r.status::text,'approved')) not in ('pending','rejected','cancelled','voided')
 and coalesce(r.meeting_date::date,(r.created_at at time zone 'Africa/Nairobi')::date)<=p.report_date),0) approved_paid
 from public.pb_loans l join clients m on m.id::text=l.member_id::text and m.business_id::text=l.business_id::text
), job as (
 select j.* from cron.job j where j.jobname='wamama-due-loan-deposits'
), funcs as (
 select n.nspname,p.proname,pg_get_functiondef(p.oid) definition from pg_proc p
 join pg_namespace n on n.oid=p.pronamespace
 where (n.nspname='wamama_deposit_private' and p.proname='release_due')
 or (n.nspname='public' and p.proname='pb_release_due_prepayments')
)
select p.report_date,
 (select count(*) from clients) matching_clients,
 (select jsonb_agg(jsonb_build_object('member_id',m.id,'member',m.full_name,'group_id',m.group_id)) from clients m) clients,
 (select jsonb_agg(jsonb_build_object('loan_id',l.id,'member_id',l.member_id,'asset_name',l.asset_name,'status',l.status,
 'start_date',l.start_date,'expected_end_date',l.expected_end_date,'total_payable',l.total_payable,'weekly_installment',l.weekly_installment,
 'approved_paid',l.approved_paid,'remaining_balance',greatest(0,l.total_payable-l.approved_paid),
 'due_including_today',greatest(0,least(l.total_payable,greatest(0,floor((p.report_date-l.start_date::date)/7.0)+1)*l.weekly_installment)-l.approved_paid),
 'arrears_before_today_after_5kes_tolerance',greatest(0,least(l.total_payable,greatest(0,ceil((p.report_date-l.start_date::date)/7.0))*l.weekly_installment)-l.approved_paid-5))) from loans l) loans,
 (select jsonb_agg(jsonb_build_object('deposit_id',d.id,'member_id',d.member_id,'linked_loan_id',d.loan_id,'source',d.source,'status',d.status,
 'payment_date',d.payment_date,'original_amount',d.excess_amount,'released_amount',d.released_amount,'remaining',d.excess_amount-coalesce(d.released_amount,0),
 'recorded_releases',d.recorded_releases,'original_payment_amount',to_jsonb(d)->>'original_payment_amount',
 'source_repayment_id',d.original_repayment_id,'receipt_status',d.receipt->>'status','receipt_voided_at',d.receipt->>'voided_at',
 'receipt_date',d.receipt->>'meeting_date','receipt_amount',d.receipt->>'amount','receipt_notes',d.receipt->>'notes',
 'reason_not_eligible',case
 when d.source is distinct from 'scheduled_prepayment' then 'Not a scheduled repayment deposit; review its purpose before using it'
 when d.status is distinct from 'pending' then 'Deposit is not pending'
 when d.excess_amount<=coalesce(d.released_amount,0) then 'No remaining cash'
 when d.payment_date is null then 'Missing deposit date'
 when d.payment_date>p.report_date then 'Future deposit date'
 when d.receipt is null then 'Missing original receipt for this member/business'
 when d.receipt->>'voided_at' is not null then 'Original receipt voided'
 when lower(coalesce(d.receipt->>'status','approved')) in ('pending','cancelled','voided') then 'Original receipt not approved'
 when lower(coalesce(d.receipt->>'status','approved'))='rejected' and coalesce((to_jsonb(d)->>'original_payment_amount')::numeric,0)<=0 then 'Rejected receipt without held-cash marker'
 when coalesce((d.receipt->>'meeting_date')::date,((d.receipt->>'created_at')::timestamptz at time zone 'Africa/Nairobi')::date)>p.report_date then 'Original receipt is future dated'
 when coalesce(d.receipt->>'notes','') like 'Auto-deducted%' or coalesce(d.receipt->>'notes','') ilike 'Scheduled prepayment release:%' then 'Internal transfer, not new cash'
 when round(coalesce(d.released_amount,0),2)<round(d.recorded_releases,2) then 'Allocation ledger and released counter disagree'
 else 'Eligible under installed shared-deposit rules' end)) from deposits d) deposit_ledger,
 (select jsonb_agg(jsonb_build_object('job_id',j.jobid,'active',j.active,'schedule',j.schedule,'command',j.command,'run_as',j.username)) from job j) automatic_job,
 (select jsonb_agg(to_jsonb(r)) from (select runs.status,runs.return_message,runs.start_time,runs.end_time
 from cron.job_run_details runs join job j on j.jobid=runs.jobid order by runs.start_time desc limit 10) r) latest_job_runs,
 (select jsonb_agg(jsonb_build_object('schema',f.nspname,'function',f.proname,'definition_md5',md5(f.definition),
 'uses_shared_worker',position('wamama_deposit_private.release_due' in f.definition)>0,
 'has_source_active_loan_restriction',position('ep.loan_id = loan_row.id::text or' in f.definition)>0,
 'has_end_date_cap',position('least(loan_row.expected_end_date' in f.definition)>0)) from funcs f) installed_logic from params p;

