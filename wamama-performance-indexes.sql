-- Wamama Pamoja Enterprise performance indexes
-- Paste this whole file into Supabase SQL Editor and run it once.
-- It is safe to run again because every index uses IF NOT EXISTS.

create or replace function public.pb_try_create_index(
  p_table text,
  p_index text,
  p_definition text
) returns void
language plpgsql
as $$
begin
  if to_regclass('public.' || p_table) is null then
    raise notice 'Skipping %, table does not exist', p_table;
    return;
  end if;

  execute format(
    'create index if not exists %I on public.%I %s',
    p_index,
    p_table,
    p_definition
  );
exception
  when undefined_column then
    raise notice 'Skipping %.% because a column is missing', p_table, p_index;
  when duplicate_table then
    raise notice 'Index % already exists', p_index;
end;
$$;

select public.pb_try_create_index('pb_staff', 'idx_pb_staff_auth_user_id', '(auth_user_id)');
select public.pb_try_create_index('pb_staff', 'idx_pb_staff_business_status_role', '(business_id, status, role)');
select public.pb_try_create_index('pb_permissions', 'idx_pb_permissions_staff_id', '(staff_id)');

select public.pb_try_create_index('pb_groups', 'idx_pb_groups_business_status', '(business_id, status)');
select public.pb_try_create_index('pb_groups', 'idx_pb_groups_business_officer', '(business_id, officer_id)');
select public.pb_try_create_index('pb_groups', 'idx_pb_groups_business_name', '(business_id, name)');
select public.pb_try_create_index('pb_groups', 'idx_pb_groups_business_mpesa_code', '(business_id, mpesa_code)');

select public.pb_try_create_index('pb_members', 'idx_pb_members_business_status', '(business_id, status)');
select public.pb_try_create_index('pb_members', 'idx_pb_members_business_group', '(business_id, group_id)');
select public.pb_try_create_index('pb_members', 'idx_pb_members_business_name', '(business_id, full_name)');
select public.pb_try_create_index('pb_members', 'idx_pb_members_business_phone', '(business_id, phone)');
select public.pb_try_create_index('pb_members', 'idx_pb_members_business_national_id', '(business_id, national_id)');
select public.pb_try_create_index('pb_members', 'idx_pb_members_business_registered_on', '(business_id, registered_on)');

select public.pb_try_create_index('pb_loans', 'idx_pb_loans_business_status', '(business_id, status)');
select public.pb_try_create_index('pb_loans', 'idx_pb_loans_business_member_status', '(business_id, member_id, status)');
select public.pb_try_create_index('pb_loans', 'idx_pb_loans_business_officer_status', '(business_id, officer_id, status)');
select public.pb_try_create_index('pb_loans', 'idx_pb_loans_business_group_status', '(business_id, group_id, status)');
select public.pb_try_create_index('pb_loans', 'idx_pb_loans_business_start_date', '(business_id, start_date)');
select public.pb_try_create_index('pb_loans', 'idx_pb_loans_business_order_id', '(business_id, order_id)');

select public.pb_try_create_index('pb_savings', 'idx_pb_savings_business_date', '(business_id, meeting_date)');
select public.pb_try_create_index('pb_savings', 'idx_pb_savings_business_member_date', '(business_id, member_id, meeting_date)');
select public.pb_try_create_index('pb_savings', 'idx_pb_savings_business_group_date', '(business_id, group_id, meeting_date)');
select public.pb_try_create_index('pb_savings', 'idx_pb_savings_business_officer_date', '(business_id, recorded_by, meeting_date)');
select public.pb_try_create_index('pb_savings', 'idx_pb_savings_business_status', '(business_id, status)');
select public.pb_try_create_index('pb_savings', 'idx_pb_savings_business_created_at', '(business_id, created_at)');

select public.pb_try_create_index('pb_repayments', 'idx_pb_repayments_business_date', '(business_id, meeting_date)');
select public.pb_try_create_index('pb_repayments', 'idx_pb_repayments_business_member_date', '(business_id, member_id, meeting_date)');
select public.pb_try_create_index('pb_repayments', 'idx_pb_repayments_business_loan_date', '(business_id, loan_id, meeting_date)');
select public.pb_try_create_index('pb_repayments', 'idx_pb_repayments_business_group_date', '(business_id, group_id, meeting_date)');
select public.pb_try_create_index('pb_repayments', 'idx_pb_repayments_business_officer_date', '(business_id, recorded_by, meeting_date)');
select public.pb_try_create_index('pb_repayments', 'idx_pb_repayments_business_status', '(business_id, status)');
select public.pb_try_create_index('pb_repayments', 'idx_pb_repayments_business_phone', '(business_id, phone)');
select public.pb_try_create_index('pb_repayments', 'idx_pb_repayments_business_created_at', '(business_id, created_at)');

select public.pb_try_create_index('pb_orders', 'idx_pb_orders_business_status', '(business_id, status)');
select public.pb_try_create_index('pb_orders', 'idx_pb_orders_business_recorded_by_date', '(business_id, recorded_by, ordered_on)');
select public.pb_try_create_index('pb_orders', 'idx_pb_orders_business_group_date', '(business_id, group_id, ordered_on)');

select public.pb_try_create_index('pb_reconciliations', 'idx_pb_reconciliations_business_group_date', '(business_id, group_id, meeting_date)');
select public.pb_try_create_index('pb_reconciliations', 'idx_pb_reconciliations_business_status', '(business_id, status)');

select public.pb_try_create_index('pb_expenses', 'idx_pb_expenses_business_date', '(business_id, date)');
select public.pb_try_create_index('pb_inventory', 'idx_pb_inventory_business_status', '(business_id, status)');
select public.pb_try_create_index('pb_purchases', 'idx_pb_purchases_business_received_on', '(business_id, received_on)');
select public.pb_try_create_index('pb_purchase_lines', 'idx_pb_purchase_lines_business_purchase', '(business_id, purchase_id)');
select public.pb_try_create_index('pb_billing_cycles', 'idx_pb_billing_cycles_business_month', '(business_id, billing_month)');

drop function public.pb_try_create_index(text, text, text);

analyze public.pb_staff;
analyze public.pb_groups;
analyze public.pb_members;
analyze public.pb_loans;
analyze public.pb_savings;
analyze public.pb_repayments;
analyze public.pb_orders;
analyze public.pb_reconciliations;
