-- Wamama financial display and repayment correction support
-- Deploy this script in Supabase before publishing the matching index.html.
-- It does not alter historical amounts. It adds an audited void marker and an
-- atomic administrator correction function for repayments entered in error.

begin;

alter table public.pb_repayments
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by text,
  add column if not exists void_reason text;

create index if not exists pb_repayments_business_voided_idx
  on public.pb_repayments (business_id, voided_at)
  where voided_at is not null;

create or replace function public.pb_void_repayment(
  p_repayment_id text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  staff_row public.pb_staff%rowtype;
  repayment_row public.pb_repayments%rowtype;
  deposit_count integer := 0;
begin
  if nullif(trim(coalesce(p_reason,'')),'') is null or length(trim(p_reason)) < 5 then
    raise exception 'A clear void reason of at least 5 characters is required.';
  end if;

  select s.* into staff_row
  from public.pb_staff s
  where s.auth_user_id = auth.uid()
    and lower(coalesce(s.status,'active')) = 'active'
  limit 1;

  if not found then
    raise exception 'Your Wamama staff session was not found.';
  end if;
  if lower(coalesce(staff_row.role,'')) not in ('admin','ceo') then
    raise exception 'Only an administrator can void a repayment.';
  end if;

  select r.* into repayment_row
  from public.pb_repayments r
  where r.id::text = p_repayment_id
    and r.business_id::text = staff_row.business_id::text
  for update;

  if not found then raise exception 'Repayment entry not found.'; end if;
  if repayment_row.voided_at is not null then raise exception 'This repayment is already voided.'; end if;

  if exists (
    select 1 from public.pb_excess_payments ep
    where ep.original_repayment_id = repayment_row.id::text
      and (coalesce(ep.released_amount,0) > 0 or lower(coalesce(ep.status,'pending')) <> 'pending')
  ) then
    raise exception 'This payment has already been released or resolved and requires a manual accounting reversal.';
  end if;

  delete from public.pb_excess_payments ep
  where ep.original_repayment_id = repayment_row.id::text
    and lower(coalesce(ep.status,'pending')) = 'pending'
    and coalesce(ep.released_amount,0) = 0;
  get diagnostics deposit_count = row_count;

  update public.pb_repayments
  set voided_at = now(),
      voided_by = staff_row.id::text,
      void_reason = trim(p_reason),
      edit_notes = concat_ws(' | ',nullif(edit_notes,''),'VOID: '||trim(p_reason)),
      updated_at = now()
  where id = repayment_row.id;

  return jsonb_build_object(
    'id',repayment_row.id,
    'voided_at',now(),
    'voided_by',staff_row.id::text,
    'cancelled_deposit_records',deposit_count
  );
end;
$$;

revoke all on function public.pb_void_repayment(text,text) from public;
grant execute on function public.pb_void_repayment(text,text) to authenticated;

commit;

select
  count(*) filter (where voided_at is not null) as voided_repayments,
  count(*) filter (where voided_at is null) as active_repayment_rows
from public.pb_repayments;
