-- Wamama Pamoja Enterprise
-- Repayment workflow safety guard.
-- This does not edit any historical repayment, loan balance, saving or deposit.

begin;

create or replace function public.pb_block_rapid_duplicate_pending_repayment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if lower(coalesce(new.status, 'pending')) <> 'pending' then
    return new;
  end if;

  if exists (
    select 1
    from public.pb_repayments r
    where r.business_id::text = new.business_id::text
      and r.member_id::text = new.member_id::text
      and r.loan_id::text = new.loan_id::text
      and coalesce(r.group_id::text, '') = coalesce(new.group_id::text, '')
      and round(coalesce(r.amount, 0)::numeric, 2) = round(coalesce(new.amount, 0)::numeric, 2)
      and coalesce(r.meeting_date, current_date) = coalesce(new.meeting_date, current_date)
      and coalesce(r.recorded_by::text, '') = coalesce(new.recorded_by::text, '')
      and lower(coalesce(r.status, 'pending')) = 'pending'
      and r.created_at >= now() - interval '30 seconds'
  ) then
    raise exception 'This repayment was already submitted. Refresh the approvals list before trying again.';
  end if;

  return new;
end;
$$;

drop trigger if exists pb_block_rapid_duplicate_pending_repayment_trigger
on public.pb_repayments;

create trigger pb_block_rapid_duplicate_pending_repayment_trigger
before insert on public.pb_repayments
for each row
execute function public.pb_block_rapid_duplicate_pending_repayment();

commit;

select
  'Wamama repayment workflow safety is ready' as result,
  0 as historical_rows_changed,
  false as loan_balances_changed,
  false as savings_changed;
