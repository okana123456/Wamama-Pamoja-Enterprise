-- Run once in Wamama Supabase. Sets the rate for new loan quotations only.
-- Existing loan totals, repayments and balances are not recalculated.
begin;
do $$
begin
  if not exists (
    select 1 from public.pb_staff
    where business_id::text = 'b3462eea-1c92-4411-9507-fb6c0b31ba28'
  ) then
    raise exception 'Wamama business not found. Use project hqxanetwkvmcfaaewnzl.';
  end if;
  update public.pb_settings
  set monthly_interest_rate = 2
  where id::text = 'biz_b3462eea-1c92-4411-9507-fb6c0b31ba28';
  if not found then
    raise exception 'Wamama settings were not found; no settings changed.';
  end if;
end;
$$;
commit;
select monthly_interest_rate,
       'Monthly flat interest set to 2%; existing loans unchanged' as result
from public.pb_settings
where id::text = 'biz_b3462eea-1c92-4411-9507-fb6c0b31ba28';
