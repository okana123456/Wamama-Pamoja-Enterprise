-- Read-only check of the September 15 dashboard figures.
-- Change the officer name if checking a supervisor or another account.
with params as (
  select '%Loida Achieng Ochogo%'::text as officer_name,
         date '2026-09-15' as report_date
), officer as (
  select s.id, s.business_id, s.full_name
  from public.pb_staff s cross join params p
  where s.full_name ilike p.officer_name
), loan_book as (
  select o.full_name, l.id, l.officer_id as original_officer_id,
         g.officer_id as current_officer_id,
         l.loan_value, l.total_payable, l.weekly_installment, l.start_date,
         coalesce(sum(r.amount) filter (where r.voided_at is null
           and coalesce(lower(r.status), 'approved') not in ('pending','rejected','cancelled')),0) as paid
  from officer o
  join public.pb_loans l on l.business_id = o.business_id and l.status = 'active'
  left join public.pb_members m on m.id = l.member_id and m.business_id = l.business_id
  left join public.pb_groups g on g.id = coalesce(m.group_id,l.group_id) and g.business_id = l.business_id
  left join public.pb_repayments r on r.loan_id = l.id and r.business_id = l.business_id
  where l.officer_id = o.id or g.officer_id = o.id
  group by o.full_name,l.id,l.officer_id,g.officer_id,l.loan_value,l.total_payable,l.weekly_installment,l.start_date
)
select full_name,
       count(*) filter (where current_officer_id is not null and current_officer_id = (select id from officer limit 1)
         or current_officer_id is null and original_officer_id = (select id from officer limit 1)) as current_active_loans,
       round(coalesce(sum(greatest(0,total_payable-paid)) filter (where current_officer_id = (select id from officer limit 1)
         or current_officer_id is null and original_officer_id = (select id from officer limit 1)),0)::numeric,2) as current_outstanding_including_interest,
       count(*) filter (where current_officer_id is not null and current_officer_id <> (select id from officer limit 1)
         and original_officer_id = (select id from officer limit 1)) as former_assignment_loans,
       round(coalesce(sum(greatest(0,total_payable-paid)) filter (where current_officer_id is not null and current_officer_id <> (select id from officer limit 1)
         and original_officer_id = (select id from officer limit 1)),0)::numeric,2) as former_assignment_outstanding,
       round(coalesce(sum(greatest(0,total_payable-paid)),0)::numeric,2) as old_dashboard_outstanding,
       count(*) filter (where (current_officer_id = (select id from officer limit 1)
         or current_officer_id is null and original_officer_id = (select id from officer limit 1))
         and greatest(0,least(greatest(0,floor(((select report_date from params)-start_date::date)/7))
           * coalesce(weekly_installment,0),coalesce(total_payable,0))-paid-5) > 0) as current_accounts_in_arrears,
       round(coalesce(sum(greatest(0,least(greatest(0,floor(((select report_date from params)-start_date::date)/7))
         * coalesce(weekly_installment,0),coalesce(total_payable,0))-paid-5)) filter
         (where current_officer_id = (select id from officer limit 1)
           or current_officer_id is null and original_officer_id = (select id from officer limit 1)),0)::numeric,2) as current_arrears_amount
from loan_book
group by full_name;
