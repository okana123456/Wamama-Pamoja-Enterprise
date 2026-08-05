-- Wamama Pamoja Enterprise
-- Guarded rollback for the future-only Excess Payments feature.
--
-- Use only before any new excess payment has been captured. The script stops
-- safely if the ledger contains activity, so it cannot discard live records.

begin;

do $$
begin
  if to_regclass('public.pb_excess_payments') is null then
    raise exception 'Rollback stopped: the Excess Payments setup is not installed.';
  end if;

  if exists (select 1 from public.pb_excess_payments) then
    raise exception 'Rollback stopped safely: excess-payment activity exists. Request a transaction-aware rollback instead.';
  end if;
end $$;

drop trigger if exists pb_capture_repayment_excess_trigger on public.pb_repayments;
drop trigger if exists pb_protect_excess_source_repayment_trigger on public.pb_repayments;

drop policy if exists pb_excess_payments_select on public.pb_excess_payments;
drop policy if exists pb_excess_payments_insert on public.pb_excess_payments;
drop policy if exists pb_excess_payments_update on public.pb_excess_payments;

drop function if exists public.pb_resolve_excess_to_savings(uuid, text);
drop function if exists public.pb_resolve_excess_as_refund(uuid, text, text);
drop function if exists public.pb_resolve_excess_to_loan(uuid, text, text);
drop function if exists public.pb_capture_repayment_excess();
drop function if exists public.pb_protect_excess_source_repayment();
drop function if exists public.pb_can_manage_excess_payments();
drop function if exists public.pb_current_business_id_text();
drop function if exists public.pb_current_staff_id_text();

drop table public.pb_excess_payments;

alter table public.pb_permissions
  drop column if exists can_manage_excess_payments;

commit;

select 'Excess Payments feature removed safely before live activity' as result;
