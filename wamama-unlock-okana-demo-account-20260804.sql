-- Unlock only the Wamama test workspace owned by okanabruce@gmail.com.
-- This records complimentary demo access for August 2026; it does not record
-- a real M-Pesa payment and cannot update any other business workspace.

do $$
declare
  v_business_id public.pb_staff.business_id%type;
  v_billing_month public.pb_billing_cycles.billing_month%type := '2026-08-01';
  v_paid_until public.pb_billing_cycles.paid_until%type := '2026-09-04';
  v_matching_accounts integer;
begin
  select count(distinct business_id)
    into v_matching_accounts
  from public.pb_staff
  where lower(trim(email)) = 'okanabruce@gmail.com';

  select business_id
    into v_business_id
  from public.pb_staff
  where lower(trim(email)) = 'okanabruce@gmail.com'
  limit 1;

  if v_matching_accounts = 0 or v_business_id is null then
    raise exception 'No Wamama staff account was found for okanabruce@gmail.com.';
  end if;

  if v_matching_accounts > 1 then
    raise exception 'More than one business is linked to okanabruce@gmail.com. Nothing was changed.';
  end if;

  update public.pb_billing_cycles
  set status = 'paid',
      amount = 0,
      paid_at = now(),
      paid_until = v_paid_until,
      receipt_number = 'COMPLIMENTARY-DEMO-AUG-2026',
      phone = null
  where business_id = v_business_id
    and billing_month = v_billing_month;

  if not found then
    insert into public.pb_billing_cycles (
      business_id,
      billing_month,
      amount,
      status,
      paid_at,
      paid_until,
      receipt_number,
      phone
    ) values (
      v_business_id,
      v_billing_month,
      0,
      'paid',
      now(),
      v_paid_until,
      'COMPLIMENTARY-DEMO-AUG-2026',
      null
    );
  end if;
end
$$;

-- Verification: this should return only the test account and a paid cycle.
select
  s.full_name,
  s.email,
  s.role,
  s.business_id,
  b.billing_month,
  b.amount,
  b.status,
  b.paid_at,
  b.paid_until,
  b.receipt_number
from public.pb_staff s
join public.pb_billing_cycles b
  on b.business_id = s.business_id
where lower(trim(s.email)) = 'okanabruce@gmail.com'
  and b.billing_month = '2026-08-01';
