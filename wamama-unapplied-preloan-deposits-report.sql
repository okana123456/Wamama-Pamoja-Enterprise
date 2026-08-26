-- Wamama Pamoja Enterprise
-- Read-only report of deposits waiting to reduce a future loan.
-- This file does not insert, update or delete any data.

with deposits as (
  select
    ep.business_id,
    ep.member_id,
    count(*) as deposit_records,
    min(ep.payment_date) as first_deposit_date,
    max(ep.payment_date) as latest_deposit_date,
    round(sum(greatest(0,ep.excess_amount-coalesce(ep.released_amount,0))),2) as available_deposit
  from public.pb_excess_payments ep
  where ep.status='pending'
    and ep.source='pre_loan_deposit'
    and ep.loan_id is null
    and ep.excess_amount>coalesce(ep.released_amount,0)
  group by ep.business_id,ep.member_id
), pending_orders as (
  select
    o.business_id::text as business_id,
    o.member_id::text as member_id,
    count(*) as pending_order_count,
    jsonb_agg(jsonb_build_object(
      'order_id',o.id,
      'product',o.asset_name,
      'ordered_on',o.ordered_on,
      'desired_weeks',o.desired_weeks,
      'desired_weekly',o.desired_weekly_installment
    ) order by o.ordered_on,o.created_at) as pending_orders
  from public.pb_orders o
  where lower(coalesce(o.status,''))='pending'
    and o.member_id is not null
  group by o.business_id::text,o.member_id::text
), active_loans as (
  select
    l.business_id::text as business_id,
    l.member_id::text as member_id,
    count(*) as active_loan_count,
    round(sum(greatest(0,coalesce(l.total_payable,0)-coalesce(r.paid,0))),2) as active_loan_balance
  from public.pb_loans l
  left join (
    select loan_id::text as loan_id,
      sum(amount) filter(where lower(coalesce(status,'approved')) not in ('pending','rejected','cancelled')) as paid
    from public.pb_repayments
    group by loan_id::text
  ) r on r.loan_id=l.id::text
  where lower(coalesce(l.status::text,''))='active'
    and l.member_id is not null
  group by l.business_id::text,l.member_id::text
), report as (
  select
    m.id as member_id,
    m.full_name as client_name,
    m.phone,
    g.name as group_name,
    d.deposit_records,
    d.first_deposit_date,
    d.latest_deposit_date,
    d.available_deposit,
    coalesce(po.pending_order_count,0) as pending_order_count,
    coalesce(po.pending_orders,'[]'::jsonb) as pending_orders,
    coalesce(al.active_loan_count,0) as active_loan_count,
    coalesce(al.active_loan_balance,0) as active_loan_balance,
    case
      when coalesce(po.pending_order_count,0)>0
        then 'Will be offered for deduction when the next pending order is approved'
      else 'Safely held until this client receives a future loan'
    end as expected_effect
  from deposits d
  join public.pb_members m
    on m.business_id::text=d.business_id and m.id::text=d.member_id
  left join public.pb_groups g on g.id::text=m.group_id::text
  left join pending_orders po
    on po.business_id=d.business_id and po.member_id=d.member_id
  left join active_loans al
    on al.business_id=d.business_id and al.member_id=d.member_id
)
select
  1 as section_order,
  'Summary' as section,
  jsonb_build_object(
    'clients_with_available_preloan_deposits',count(*),
    'total_available_preloan_deposits',coalesce(sum(available_deposit),0),
    'clients_with_pending_orders',count(*) filter(where pending_order_count>0),
    'amount_ready_for_pending_orders',coalesce(sum(available_deposit) filter(where pending_order_count>0),0),
    'financial_data_changed',false
  ) as result
from report

union all

select
  2,
  'Clients whose deposits will affect future loan financing',
  coalesce(jsonb_agg(jsonb_build_object(
    'member_id',member_id,
    'client_name',client_name,
    'phone',phone,
    'group_name',group_name,
    'available_deposit',available_deposit,
    'deposit_records',deposit_records,
    'first_deposit_date',first_deposit_date,
    'latest_deposit_date',latest_deposit_date,
    'pending_order_count',pending_order_count,
    'pending_orders',pending_orders,
    'active_loan_count',active_loan_count,
    'active_loan_balance',active_loan_balance,
    'expected_effect',expected_effect
  ) order by available_deposit desc,client_name),'[]'::jsonb)
from report
order by section_order;
