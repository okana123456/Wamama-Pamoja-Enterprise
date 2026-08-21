-- Wamama Pamoja Enterprise
-- Sold-form client/inventory controls, 6% correction, and pre-loan deposits.
-- Run this complete file once in the Wamama Supabase SQL Editor.

begin;

-- A future-loan deposit exists before a loan_id is available.
alter table public.pb_excess_payments
  alter column loan_id drop not null;

create index if not exists pb_excess_payments_unattached_deposit_idx
  on public.pb_excess_payments (business_id, member_id, payment_date)
  where status = 'pending' and source = 'pre_loan_deposit' and loan_id is null;

create or replace function public.pb_record_preloan_deposit(
  p_member_id text,
  p_amount numeric,
  p_payment_date date default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.pb_staff%rowtype;
  v_member public.pb_members%rowtype;
  v_allowed boolean := false;
  v_row public.pb_excess_payments%rowtype;
begin
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'Deposit amount must be greater than zero.';
  end if;

  select s.* into v_staff
  from public.pb_staff s
  where s.auth_user_id = auth.uid()
    and lower(coalesce(s.status, 'active')) = 'active'
  limit 1;

  if not found then raise exception 'Your Wamama staff session was not found.'; end if;

  select (
    lower(coalesce(v_staff.role, '')) in ('admin','ceo','branch_manager','supervisor','officer','loan_officer')
    or coalesce(p.can_record_repayments, false)
  ) into v_allowed
  from public.pb_permissions p
  where p.staff_id::text = v_staff.id::text;

  v_allowed := coalesce(v_allowed,
    lower(coalesce(v_staff.role, '')) in ('admin','ceo','branch_manager','supervisor','officer','loan_officer'));
  if not v_allowed then raise exception 'You do not have permission to record loan deposits.'; end if;

  select m.* into v_member
  from public.pb_members m
  where m.id::text = p_member_id
    and m.business_id::text = v_staff.business_id::text
    and lower(coalesce(m.status, 'active')) = 'active'
  limit 1;
  if not found then raise exception 'Select an active client from your Wamama business.'; end if;

  insert into public.pb_excess_payments (
    business_id, member_id, group_id, loan_id, original_repayment_id,
    payment_date, original_payment_amount, amount_applied_to_loan,
    excess_amount, released_amount, status, source, notes
  ) values (
    v_staff.business_id::text, v_member.id::text, v_member.group_id::text,
    null, null, coalesce(p_payment_date, (now() at time zone 'Africa/Nairobi')::date),
    p_amount, 0, p_amount, 0, 'pending', 'pre_loan_deposit',
    concat_ws(' | ', 'Deposit received before loan issuance', nullif(trim(p_note), ''))
  ) returning * into v_row;

  return jsonb_build_object(
    'id', v_row.id,
    'member_id', v_row.member_id,
    'amount', v_row.excess_amount,
    'payment_date', v_row.payment_date,
    'status', v_row.status
  );
end;
$$;

grant execute on function public.pb_record_preloan_deposit(text,numeric,date,text) to authenticated;
revoke all on function public.pb_record_preloan_deposit(text,numeric,date,text) from public, anon;

-- Attach any deposits collected before funding to the member's newly activated loan.
create or replace function public.pb_attach_preloan_deposits()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if lower(coalesce(new.status::text, '')) = 'active'
     and new.member_id is not null
     and (tg_op = 'INSERT' or lower(coalesce(old.status::text, '')) <> 'active') then
    update public.pb_excess_payments ep
    set loan_id = new.id::text,
        group_id = coalesce(new.group_id::text, ep.group_id),
        source = 'scheduled_prepayment',
        notes = concat_ws(' | ', nullif(ep.notes, ''),
          'Attached automatically to funded loan ' || new.id::text),
        updated_at = now()
    where ep.business_id = new.business_id::text
      and ep.member_id = new.member_id::text
      and ep.status = 'pending'
      and ep.source = 'pre_loan_deposit'
      and ep.loan_id is null;
  end if;
  return new;
end;
$$;

drop trigger if exists pb_attach_preloan_deposits_trigger on public.pb_loans;
create trigger pb_attach_preloan_deposits_trigger
after insert or update of status on public.pb_loans
for each row execute function public.pb_attach_preloan_deposits();

-- Approve a sold-form loan only after checking its links and stock.
create or replace function public.pb_approve_sold_items_loan(p_loan_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.pb_staff%rowtype;
  v_loan public.pb_loans%rowtype;
  v_asset public.pb_inventory%rowtype;
  v_allowed boolean := false;
  v_order_status text := 'pending';
begin
  select s.* into v_staff
  from public.pb_staff s
  where s.auth_user_id = auth.uid()
    and lower(coalesce(s.status, 'active')) = 'active'
  limit 1;
  if not found then raise exception 'Your Wamama staff session was not found.'; end if;

  select (
    lower(coalesce(v_staff.role, '')) in ('admin','ceo','branch_manager','supervisor')
    or coalesce(p.can_approve_orders, false)
  ) into v_allowed
  from public.pb_permissions p
  where p.staff_id::text = v_staff.id::text;
  v_allowed := coalesce(v_allowed,
    lower(coalesce(v_staff.role, '')) in ('admin','ceo','branch_manager','supervisor'));
  if not v_allowed then raise exception 'You do not have permission to approve sold-form loans.'; end if;

  select l.* into v_loan
  from public.pb_loans l
  where l.id::text = p_loan_id
    and l.business_id::text = v_staff.business_id::text
  for update;
  if not found then raise exception 'Sold-form loan not found.'; end if;
  if lower(coalesce(v_loan.status::text, '')) = 'active' then
    raise exception 'This loan is already active.';
  end if;
  if lower(coalesce(v_loan.status::text, '')) <> 'pending' then
    raise exception 'Only pending sold-form loans can be approved.';
  end if;
  if v_loan.member_id is null then raise exception 'Approval blocked: select a registered client first.'; end if;
  if v_loan.asset_id is null then raise exception 'Approval blocked: select an inventory item first.'; end if;

  perform 1 from public.pb_members m
  where m.id::text = v_loan.member_id::text
    and m.business_id::text = v_staff.business_id::text
    and lower(coalesce(m.status, 'active')) = 'active';
  if not found then raise exception 'Approval blocked: the linked client is missing or inactive.'; end if;

  select i.* into v_asset
  from public.pb_inventory i
  where i.id::text = v_loan.asset_id::text
    and i.business_id::text = v_staff.business_id::text
  for update;
  if not found then raise exception 'Approval blocked: the linked inventory item was not found.'; end if;
  if coalesce(v_asset.stock, 0) < greatest(1, coalesce(v_loan.asset_quantity, 1)) then
    raise exception 'Approval blocked: insufficient stock for %. Available %, required %.',
      v_asset.name, coalesce(v_asset.stock, 0), greatest(1, coalesce(v_loan.asset_quantity, 1));
  end if;

  update public.pb_inventory
  set stock = stock - greatest(1, coalesce(v_loan.asset_quantity, 1))
  where id = v_asset.id;

  update public.pb_loans set status = 'active' where id = v_loan.id;

  if v_loan.order_id is not null then
    if exists (
      select 1 from public.pb_loans l
      where l.order_id::text = v_loan.order_id::text
        and l.id::text <> v_loan.id::text
        and lower(coalesce(l.status::text, '')) = 'pending'
    ) then
      v_order_status := 'pending';
    else
      v_order_status := 'fulfilled';
    end if;
    update public.pb_orders
    set status = v_order_status, approved_by = v_staff.id
    where id::text = v_loan.order_id::text;
  end if;

  return jsonb_build_object(
    'loan_id', v_loan.id,
    'loan_status', 'active',
    'asset_id', v_asset.id,
    'stock_remaining', v_asset.stock - greatest(1, coalesce(v_loan.asset_quantity, 1)),
    'order_status', v_order_status
  );
end;
$$;

grant execute on function public.pb_approve_sold_items_loan(text) to authenticated;
revoke all on function public.pb_approve_sold_items_loan(text) from public, anon;

-- Preserve pending sold-form loans before correcting only unapproved 12% totals.
create table if not exists public.pb_sold_items_6pct_backup_20260821
(like public.pb_loans including defaults);
create unique index if not exists pb_sold_items_6pct_backup_20260821_id_uidx
  on public.pb_sold_items_6pct_backup_20260821 (id);

insert into public.pb_sold_items_6pct_backup_20260821
select l.*
from public.pb_loans l
join public.pb_orders o on o.id::text = l.order_id::text
where lower(coalesce(l.status::text, '')) = 'pending'
  and coalesce(o.notes, '') like '%"source":"sold_items"%'
on conflict (id) do nothing;

with corrected as (
  select l.id,
         greatest(1, round((l.expected_end_date - l.start_date)::numeric / 7)) as weeks,
         round(
           l.loan_value
           + (l.loan_value * 0.06)
           + (l.loan_value * 0.02 * (greatest(1, round((l.expected_end_date - l.start_date)::numeric / 7)) / 4)),
           2
         ) as corrected_total
  from public.pb_loans l
  join public.pb_orders o on o.id::text = l.order_id::text
  where lower(coalesce(l.status::text, '')) = 'pending'
    and coalesce(o.notes, '') like '%"source":"sold_items"%'
    and not exists (
      select 1 from public.pb_repayments r
      where r.loan_id::text = l.id::text
        and lower(coalesce(r.status, 'approved')) not in ('pending','rejected','cancelled')
    )
)
update public.pb_loans l
set total_payable = c.corrected_total,
    weekly_installment = round(c.corrected_total / c.weeks, 2)
from corrected c
where l.id = c.id;

commit;

select
  'Wamama sold form, 6% charge, inventory approval and pre-loan deposits are ready' as result,
  (select count(*) from public.pb_loans l join public.pb_orders o on o.id::text=l.order_id::text
    where lower(coalesce(l.status::text,''))='pending' and coalesce(o.notes,'') like '%"source":"sold_items"%') as pending_sold_loans_checked,
  (select count(*) from public.pb_excess_payments where status='pending' and source='pre_loan_deposit' and loan_id is null) as future_loan_deposits,
  false as ordinary_savings_changed,
  false as approved_loan_balances_changed;
