-- Wamama Pamoja Enterprise
-- APPLY: restore historical loan deposits / prepayments that were previously moved into savings.
--
-- Run the preview file first.
--
-- What this does:
-- 1. Finds pb_excess_payments currently marked transferred_to_savings.
-- 2. Finds only the exact matching auto-created savings rows using the transfer note.
-- 3. Marks those savings rows rejected so they no longer count as normal savings.
-- 4. Marks the corresponding pb_excess_payments rows as pending loan deposits / prepayments.
--
-- It does NOT touch ordinary savings entries.

begin;

with matched as (
  select distinct
    ep.id as loan_deposit_id,
    s.id as savings_id
  from public.pb_excess_payments ep
  join public.pb_savings s
    on s.member_id::text = ep.member_id::text
   and s.business_id::text = ep.business_id::text
   and lower(coalesce(s.status, 'approved')) = 'approved'
   and (
     s.notes = 'Loan overpayment transferred to savings; repayment ' || ep.original_repayment_id::text
     or s.notes = 'Historical loan overpayment transferred to savings; excess record ' || ep.id::text
   )
  where ep.status = 'transferred_to_savings'
),
reject_savings as (
  update public.pb_savings s
  set
    status = 'rejected',
    notes = concat_ws(' | ', nullif(s.notes, ''), 'Reversed from savings and restored as loan deposit / prepayment.')
  from matched m
  where s.id = m.savings_id
  returning s.id
),
restore_deposits as (
  update public.pb_excess_payments ep
  set
    status = 'pending',
    resolved_at = null,
    resolved_by = null,
    resolution_reference = null,
    notes = concat_ws(' | ', nullif(ep.notes, ''), 'Restored from savings to loan deposit / prepayment.'),
    updated_at = now()
  from matched m
  where ep.id = m.loan_deposit_id
  returning ep.id, ep.excess_amount
)
select
  'Historical loan deposits restored from savings' as result,
  (select count(*) from reject_savings) as savings_rows_reversed,
  (select count(*) from restore_deposits) as loan_deposit_rows_restored,
  (select coalesce(sum(excess_amount), 0) from restore_deposits) as amount_restored;

commit;

select
  status,
  count(*) as records,
  coalesce(sum(excess_amount), 0) as total_amount
from public.pb_excess_payments
group by status
order by status;
