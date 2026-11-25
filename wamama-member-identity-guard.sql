-- Install before cleanup. Stops new ID conflicts while retaining all existing accounts.
-- Existing duplicates, balances and histories are unchanged.
begin;
create index if not exists pb_members_business_normalized_identity_idx
on public.pb_members ((business_id::text),
 (lower(regexp_replace(trim(coalesce(national_id,'')),'\s+',' ','g'))));

create or replace function public.pb_guard_member_identity()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare identity_key text:=lower(regexp_replace(trim(coalesce(new.national_id,'')),'\s+',' ','g'));
begin
 if tg_op='UPDATE' then
  if new.business_id::text is not distinct from old.business_id::text
   and identity_key=lower(regexp_replace(trim(coalesce(old.national_id,'')),'\s+',' ','g')) then
   return new;
  end if;
 end if;
 if nullif(trim(new.business_id::text),'') is null then raise exception 'A business is required for this client account.'; end if;
 if identity_key='' then raise exception 'A national ID is required for a new client account or identity change.'; end if;
 perform pg_advisory_xact_lock(hashtextextended('wamama-member-identity:'||new.business_id::text||':'||identity_key,0));
 if exists(select 1 from public.pb_members m
  where m.business_id::text=new.business_id::text
  and lower(regexp_replace(trim(coalesce(m.national_id,'')),'\s+',' ','g'))=identity_key
  and (tg_op='INSERT' or m.id::text is distinct from new.id::text)) then
  raise exception 'This national ID already has a client account, including inactive accounts. Use that account, or ask an authorized manager to reactivate it or arrange a group transfer.';
 end if;
 return new;
end;
$$;
revoke all on function public.pb_guard_member_identity() from public,anon,authenticated;
drop trigger if exists pb_aa_guard_member_identity_trigger on public.pb_members;
create trigger pb_aa_guard_member_identity_trigger
before insert or update of national_id,business_id on public.pb_members
for each row execute function public.pb_guard_member_identity();
commit;
select 'New repeat national-ID registrations blocked; existing accounts and financial history unchanged' result,
 exists(select 1 from pg_trigger where tgrelid='public.pb_members'::regclass
 and tgname='pb_aa_guard_member_identity_trigger' and tgenabled='O') identity_guard_enabled;
