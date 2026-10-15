-- Read-only reporting setup. Does not change repayments, savings or recorded_by.
create or replace function public.pb_officer_book_activity(p_start date,p_end date)
returns jsonb language sql stable security definer set search_path=''
as $$
with context as (
 select s.* from public.pb_staff s where s.auth_user_id=auth.uid()
 and lower(coalesce(s.status,'active'))='active' order by s.id limit 1
), receipts as (
 select c.id caller_id,c.role caller_role,c.team_name caller_team,
 case when g.id is null then l.officer_id::text else g.officer_id::text end officer_id,
 g.id::text group_id,coalesce(ep.original_payment_amount,r.amount,0)::numeric collections,
 case when lower(coalesce(r.status::text,'approved'))='rejected' then 0 else coalesce(r.interest,0) end::numeric interest,
 0::numeric savings,c.business_id::text business_id
 from context c join public.pb_repayments r on r.business_id::text=c.business_id::text
 left join public.pb_members m on m.id::text=r.member_id::text and m.business_id::text=c.business_id::text
 left join public.pb_loans l on l.id::text=r.loan_id::text and l.business_id::text=c.business_id::text
 left join public.pb_groups g on g.id::text=coalesce(m.group_id::text,r.group_id::text,l.group_id::text)
 and g.business_id::text=c.business_id::text
 left join lateral (
 select e.original_payment_amount,e.status from public.pb_excess_payments e
 where e.original_repayment_id::text=r.id::text and e.business_id::text=c.business_id::text
 and e.source='scheduled_prepayment' order by e.created_at,e.id limit 1
 ) ep on true
 where r.voided_at is null and lower(coalesce(r.status::text,'approved')) not in ('pending','cancelled','voided')
 and (lower(coalesce(r.status::text,'approved'))<>'rejected' or ep.original_payment_amount is not null)
 and lower(coalesce(ep.status,'pending')) not in ('refunded','cancelled','rejected')
 and coalesce(r.notes,'') not like 'Auto-deducted%'
 and coalesce(r.notes,'') not ilike 'Scheduled prepayment release:%'
 and coalesce(r.meeting_date::date,(r.created_at at time zone 'Africa/Nairobi')::date) between p_start and p_end
 union all
 select c.id,c.role,c.team_name,g.officer_id::text,g.id::text,0::numeric,0::numeric,
 coalesce(s.amount,0)::numeric,c.business_id::text
 from context c join public.pb_savings s on s.business_id::text=c.business_id::text
 left join public.pb_members m on m.id::text=s.member_id::text and m.business_id::text=c.business_id::text
 left join public.pb_groups g on g.id::text=coalesce(m.group_id::text,s.group_id::text)
 and g.business_id::text=c.business_id::text
 where to_jsonb(s)->>'voided_at' is null
 and lower(coalesce(s.status::text,'approved')) not in ('pending','rejected','cancelled','voided')
 and coalesce(s.meeting_date::date,(s.created_at at time zone 'Africa/Nairobi')::date) between p_start and p_end
), authorized as (
 select r.* from receipts r
 left join public.pb_staff owner on owner.id::text=r.officer_id and owner.business_id::text=r.business_id
 where lower(r.caller_role) in ('admin','ceo','branch_manager','inventory_officer','storekeeper')
 or r.officer_id=r.caller_id::text
 or (lower(r.caller_role)='supervisor' and nullif(lower(trim(r.caller_team)),'') is not null
 and lower(trim(owner.team_name))=lower(trim(r.caller_team)))
), totals as (
 select officer_id,group_id,round(sum(collections),2) collections,
 round(sum(interest),2) interest,round(sum(savings),2) savings
 from authorized group by officer_id,group_id
)
select jsonb_build_object('version',1,'authorized',exists(select 1 from context),
 'start',p_start,'end',p_end,'checkedAt',now(),
 'rows',coalesce(jsonb_agg(jsonb_build_object('officerId',officer_id,'groupId',group_id,
 'collections',collections,'interest',interest,'savings',savings)),'[]'::jsonb)) from totals;
$$;
revoke all on function public.pb_officer_book_activity(date,date) from public,anon;
grant execute on function public.pb_officer_book_activity(date,date) to authenticated;
select 'Officer book reporting installed; original payment records unchanged' result;
