-- Wamama Pamoja Enterprise
-- Read-only trace for Agnes Nzilani Mutisya's reported pre-loan deposit.
-- This file does not insert, update or delete any data.

with target as (
  select
    'a8ae14a2-090d-4505-a8f4-8528e4aef66c'::text as member_id,
    'b3462eea-1c92-4411-9507-fb6c0b31ba28'::text as business_id
), entries as (
  select
    'Savings'::text as record_type,
    s.id::text as record_id,
    to_jsonb(s) as row_data
  from public.pb_savings s, target t
  where s.member_id::text=t.member_id
    and s.business_id::text=t.business_id

  union all

  select
    'Repayment'::text,
    r.id::text,
    to_jsonb(r)
  from public.pb_repayments r, target t
  where r.member_id::text=t.member_id
    and r.business_id::text=t.business_id

  union all

  select
    'Loan deposit / prepayment'::text,
    ep.id::text,
    to_jsonb(ep)
  from public.pb_excess_payments ep, target t
  where ep.member_id=t.member_id
    and ep.business_id=t.business_id
), normalised as (
  select
    record_type,
    record_id,
    coalesce(
      row_data->>'meeting_date',
      row_data->>'payment_date',
      left(row_data->>'created_at',10)
    ) as entry_date,
    coalesce(
      nullif(row_data->>'amount','')::numeric,
      nullif(row_data->>'excess_amount','')::numeric,
      nullif(row_data->>'original_payment_amount','')::numeric,
      0
    ) as amount,
    coalesce(row_data->>'status','') as status,
    coalesce(row_data->>'source','') as source,
    coalesce(row_data->>'notes','') as notes,
    row_data->>'loan_id' as loan_id,
    row_data
  from entries
), summary as (
  select jsonb_build_object(
    'client_name','Agnes Nzilani Mutisya',
    'member_id',(select member_id from target),
    'savings_rows',count(*) filter(where record_type='Savings'),
    'savings_total',coalesce(sum(amount) filter(where record_type='Savings' and lower(status) not in ('pending','rejected','cancelled')),0),
    'repayment_rows',count(*) filter(where record_type='Repayment'),
    'repayment_total',coalesce(sum(amount) filter(where record_type='Repayment' and lower(status) not in ('pending','rejected','cancelled')),0),
    'loan_deposit_rows',count(*) filter(where record_type='Loan deposit / prepayment'),
    'available_preloan_deposit',coalesce(sum(
      case when record_type='Loan deposit / prepayment'
        and status='pending' and source='pre_loan_deposit' and loan_id is null
        then greatest(0,
          coalesce(nullif(row_data->>'excess_amount','')::numeric,0)
          - coalesce(nullif(row_data->>'released_amount','')::numeric,0)
        ) else 0 end
    ),0)
  ) as result
  from normalised
), details as (
  select jsonb_agg(jsonb_build_object(
    'record_type',record_type,
    'record_id',record_id,
    'date',entry_date,
    'amount',amount,
    'status',status,
    'source',source,
    'loan_id',loan_id,
    'notes',notes
  ) order by entry_date desc nulls last,record_type,record_id) as result
  from normalised
)
select 1 as section_order,'Agnes financial-entry summary' as section,result from summary
union all
select 2,'Agnes complete savings, repayment and deposit trace',coalesce(result,'[]'::jsonb) from details
order by section_order;
