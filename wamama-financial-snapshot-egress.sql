-- Wamama Pamoja Enterprise
-- Lower-egress financial snapshot.
--
-- pb_financial_snapshot returns the full list of visible loan IDs (about
-- 140 KB for 3,600 loans) on every call, including the small refreshes that
-- follow each payment. This wrapper returns the same snapshot, plus a short
-- fingerprint of that list, and leaves the list out when the browser says it
-- already has it. The browser asks for the full list again whenever the
-- fingerprint changes.
--
-- Read-only: calls the existing pb_financial_snapshot with the caller's own
-- permissions (security invoker), changes no data and no existing function.
-- Safe to run more than once.

begin;

create or replace function public.pb_financial_snapshot_v2(
  p_loan_ids text[] default null,
  p_since timestamptz default null,
  p_include_ids boolean default true)
returns jsonb
language sql stable security invoker
set search_path = public
as $$
  with s as (select public.pb_financial_snapshot(p_loan_ids, p_since) as j)
  select (case when p_include_ids then j else j - 'visibleLoanIds' end)
      || jsonb_build_object(
           'visibleLoanIdsHash', md5(coalesce(j->'visibleLoanIds', '[]'::jsonb)::text),
           'visibleLoanCount', jsonb_array_length(coalesce(j->'visibleLoanIds', '[]'::jsonb)),
           'includesVisibleLoanIds', p_include_ids)
  from s;
$$;

revoke all on function public.pb_financial_snapshot_v2(text[], timestamptz, boolean) from public, anon;
grant execute on function public.pb_financial_snapshot_v2(text[], timestamptz, boolean) to authenticated;

commit;

select 'Lower-egress financial snapshot installed; data unchanged' as result,
  has_function_privilege('authenticated','public.pb_financial_snapshot_v2(text[],timestamptz,boolean)','execute') as signed_in_allowed,
  has_function_privilege('anon','public.pb_financial_snapshot_v2(text[],timestamptz,boolean)','execute') as anonymous_allowed;
