-- Run AFTER wamama-authorized-product-deposit-transfer.sql.
-- Authorized targeted correction: apply 189.06 from ONE existing 1300 product deposit.
-- Preserve both original deposits; matching date/amount alone does not prove duplication.
do $nancy$
declare v_result jsonb;
begin
 if not exists(select 1 from wamama_deposit_private.product_deposit_transfers where request_id='nancy-product-deposit-due-20261031') then
  if not exists(select 1 from public.pb_loans where id::text='4fd917fb-0122-4665-abea-275558df52b4'
   and business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28' and member_id::text='9962dd1c-f7f8-4c0d-b2c9-8398cb05e568'
   and status='active' and total_payable=6272 and weekly_installment=522.67 and start_date::date='2026-10-30') then
   raise exception 'Nancy loan changed. No transfer made; refresh the diagnostic first.';
  end if;
 end if;
 v_result:=wamama_deposit_private.apply_product_deposit(
 'b3462eea-1c92-4411-9507-fb6c0b31ba28','sql-editor:'||current_user,
 '018b67fb-c46e-4131-a805-e688b102ae6e','4fd917fb-0122-4665-abea-275558df52b4',189.06,
 'Management-authorized product deposit transfer to Nancy unpaid instalment; original receipts retained for review',
 'nancy-product-deposit-due-20261031');
end;
$nancy$;
with params as(select (now() at time zone 'Africa/Nairobi')::date today), paid as(
 select coalesce(sum(r.amount),0) amount from public.pb_repayments r cross join params p
 where r.loan_id::text='4fd917fb-0122-4665-abea-275558df52b4' and r.business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28'
 and r.voided_at is null and lower(coalesce(r.status::text,'approved')) not in ('pending','rejected','cancelled','voided')
 and coalesce(r.meeting_date,(r.created_at at time zone 'Africa/Nairobi')::date)<=p.today
)
select p.today report_date,l.id loan_id,paid.amount approved_paid,
 greatest(0,least(l.total_payable,greatest(0,floor((p.today-l.start_date::date)/7.0)+1)*l.weekly_installment)-paid.amount) unpaid_due_including_today,
 greatest(0,l.total_payable-paid.amount) remaining_loan_balance,
 (select sum(ep.excess_amount-coalesce(ep.released_amount,0)) from public.pb_excess_payments ep
 where ep.member_id::text=l.member_id::text and ep.business_id::text=l.business_id::text and ep.source='pre_loan_deposit' and ep.status='pending') remaining_product_deposits
from public.pb_loans l cross join paid cross join params p where l.id::text='4fd917fb-0122-4665-abea-275558df52b4';
