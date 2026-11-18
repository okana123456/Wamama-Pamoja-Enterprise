-- Install before further meeting submissions. Does not alter financial records.
begin;
create or replace function public.pb_guard_repeated_meeting_receipt()
returns trigger language plpgsql security definer
set search_path=pg_catalog, public, pg_temp
as $$
begin
  if new.meeting_id is null
    or coalesce(new.notes,'') like 'Scheduled prepayment release:%'
    or coalesce(new.notes,'') like 'Auto-deducted%' then return new; end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'wamama-meeting-receipt:' || new.business_id::text || ':' || new.meeting_id::text
    || ':' || new.loan_id::text || ':' || coalesce(new.recorded_by::text,''),0));
  if exists (
    select 1 from public.pb_repayments r
    where r.business_id::text=new.business_id::text
      and r.meeting_id::text=new.meeting_id::text
      and r.loan_id::text=new.loan_id::text
      and r.member_id::text=new.member_id::text
      and coalesce(r.recorded_by::text,'')=coalesce(new.recorded_by::text,'')
      and r.meeting_date is not distinct from new.meeting_date
      and r.voided_at is null
      and coalesce(r.notes,'') not like 'Scheduled prepayment release:%'
      and coalesce(r.notes,'') not like 'Auto-deducted%'
      and (
        (lower(r.status) in ('pending','approved') and round(r.amount::numeric,2)=round(new.amount::numeric,2))
        or exists(select 1 from public.pb_excess_payments ep
          where ep.original_repayment_id::text=r.id::text
            and ep.business_id::text=r.business_id::text
            and ep.source='scheduled_prepayment'
            and lower(ep.status) not in ('cancelled','refunded','rejected')
            and round(ep.original_payment_amount::numeric,2)=round(new.amount::numeric,2)
            and (lower(r.status)='approved' or (
              lower(r.status)='rejected'
              and coalesce(r.edit_notes,'') like '%Full amount held in loan prepayment account%'
              and coalesce(r.edit_notes,'') not ilike '%Rejection reason:%')))
      )
  ) then
    raise exception 'This meeting payment is already recorded, including any amount held as a deposit. Refresh before recording another payment.';
  end if;
  return new;
end;
$$;
revoke all on function public.pb_guard_repeated_meeting_receipt() from public,anon,authenticated;
drop trigger if exists pb_aa_guard_repeated_meeting_receipt_trigger on public.pb_repayments;
create trigger pb_aa_guard_repeated_meeting_receipt_trigger before insert on public.pb_repayments
for each row execute function public.pb_guard_repeated_meeting_receipt();
commit;
select 'Repeated meeting-payment safeguard installed; financial records unchanged' as result;
