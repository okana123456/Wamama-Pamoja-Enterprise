-- Prevent repeats of the same meeting saving, even after approval or after 30 seconds.
-- Historical savings are not changed. Separate non-meeting payments remain possible.
begin;
create or replace function public.pb_guard_repeated_meeting_saving()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
 if new.meeting_id is null then return new; end if;
 perform pg_advisory_xact_lock(hashtextextended('wamama-meeting-saving:'||new.business_id::text||':'||new.meeting_id::text
 ||':'||new.member_id::text||':'||coalesce(new.recorded_by::text,''),0));
 if exists(select 1 from public.pb_savings s where s.business_id::text=new.business_id::text
 and s.meeting_id::text=new.meeting_id::text and s.member_id::text=new.member_id::text
 and coalesce(s.recorded_by::text,'')=coalesce(new.recorded_by::text,'')
 and s.meeting_date is not distinct from new.meeting_date
 and round(s.amount::numeric,2)=round(new.amount::numeric,2)
 and lower(s.status) in ('approved','pending') and nullif(to_jsonb(s)->>'voided_at','') is null)
 then raise exception 'This meeting saving is already recorded. Refresh before recording another payment.'; end if;
 return new;
end;
$$;
revoke all on function public.pb_guard_repeated_meeting_saving() from public,anon,authenticated;
drop trigger if exists pb_aa_guard_repeated_meeting_saving_trigger on public.pb_savings;
create trigger pb_aa_guard_repeated_meeting_saving_trigger before insert on public.pb_savings
for each row execute function public.pb_guard_repeated_meeting_saving();
commit;
select 'Repeated meeting-savings safeguard installed; historical records unchanged' result;
