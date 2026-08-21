-- Wamama Pamoja Enterprise
-- Group sold-item approvals by client/form and allow genuine multiple loans.
-- Exact duplicate loans remain blocked. No existing balances are recalculated.
-- Run this complete file once in the Wamama Supabase SQL Editor.

begin;

create table if not exists public.pb_loan_trigger_backup_20260821 (
  trigger_name text primary key,
  function_name text not null,
  trigger_definition text not null,
  backed_up_at timestamptz not null default now()
);

insert into public.pb_loan_trigger_backup_20260821
  (trigger_name, function_name, trigger_definition)
select t.tgname, p.proname, pg_get_triggerdef(t.oid, true)
from pg_trigger t
join pg_class c on c.oid=t.tgrelid
join pg_namespace n on n.oid=c.relnamespace
join pg_proc p on p.oid=t.tgfoid
where n.nspname='public' and c.relname='pb_loans'
  and not t.tgisinternal
  and p.proname in ('prevent_multiple_active_loans','pb_validate_wamama_active_loan_rules')
on conflict (trigger_name) do nothing;

-- Remove only the previous broad one-active-loan guards. A narrower exact-
-- duplicate guard is installed below.
do $$
declare v_trigger record;
begin
  for v_trigger in
    select t.tgname
    from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    join pg_proc p on p.oid=t.tgfoid
    where n.nspname='public' and c.relname='pb_loans'
      and not t.tgisinternal
      and p.proname in ('prevent_multiple_active_loans','pb_validate_wamama_active_loan_rules')
  loop
    execute format('drop trigger if exists %I on public.pb_loans',v_trigger.tgname);
  end loop;
end;
$$;

create or replace function public.pb_block_exact_duplicate_active_loans()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  if lower(coalesce(new.status::text,''))<>'active' or new.member_id is null then
    return new;
  end if;

  if exists (
    select 1
    from public.pb_loans l
    where l.business_id::text=new.business_id::text
      and l.member_id::text=new.member_id::text
      and l.id is distinct from new.id
      and lower(coalesce(l.status::text,''))='active'
      and coalesce(l.order_id::text,'')=coalesce(new.order_id::text,'')
      and coalesce(l.asset_id::text,'')=coalesce(new.asset_id::text,'')
      and lower(trim(coalesce(l.asset_name,'')))=lower(trim(coalesce(new.asset_name,'')))
      and coalesce(l.loan_value,0)=coalesce(new.loan_value,0)
      and l.start_date is not distinct from new.start_date
  ) then
    raise exception 'An identical active loan already exists for this client. Review the existing loan instead of creating a duplicate.';
  end if;

  return new;
end;
$$;

drop trigger if exists pb_block_exact_duplicate_active_loans_trigger on public.pb_loans;
create trigger pb_block_exact_duplicate_active_loans_trigger
before insert or update of status,member_id,order_id,asset_id,loan_value,start_date on public.pb_loans
for each row execute function public.pb_block_exact_duplicate_active_loans();

create or replace function public.pb_approve_sold_items_loan_group(
  p_order_id text,
  p_member_id text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_staff public.pb_staff%rowtype;
  v_order public.pb_orders%rowtype;
  v_member public.pb_members%rowtype;
  v_asset public.pb_inventory%rowtype;
  v_stock record;
  v_allowed boolean:=false;
  v_count integer:=0;
  v_order_status text:='pending';
  v_loan_ids jsonb:='[]'::jsonb;
  v_stock_updates jsonb:='[]'::jsonb;
begin
  select s.* into v_staff
  from public.pb_staff s
  where s.auth_user_id=auth.uid()
    and lower(coalesce(s.status,'active'))='active'
  limit 1;
  if not found then raise exception 'Your Wamama staff session was not found.'; end if;

  select (
    lower(coalesce(v_staff.role,'')) in ('admin','ceo','branch_manager','supervisor')
    or coalesce(p.can_approve_orders,false)
  ) into v_allowed
  from public.pb_permissions p
  where p.staff_id::text=v_staff.id::text;
  v_allowed:=coalesce(v_allowed,
    lower(coalesce(v_staff.role,'')) in ('admin','ceo','branch_manager','supervisor'));
  if not v_allowed then raise exception 'You do not have permission to approve sold-form loans.'; end if;

  select o.* into v_order
  from public.pb_orders o
  where o.id::text=p_order_id
    and o.business_id::text=v_staff.business_id::text
  for update;
  if not found then raise exception 'Sold Items Form not found.'; end if;
  if coalesce(v_order.notes,'') not like '%"source":"sold_items"%' then
    raise exception 'This is not a Sold Items Form.';
  end if;

  select m.* into v_member
  from public.pb_members m
  where m.id::text=p_member_id
    and m.business_id::text=v_staff.business_id::text
    and lower(coalesce(m.status,'active'))='active';
  if not found then raise exception 'The linked client is missing or inactive.'; end if;

  select count(*) into v_count
  from public.pb_loans l
  where l.order_id::text=p_order_id
    and l.member_id::text=p_member_id
    and l.business_id::text=v_staff.business_id::text
    and lower(coalesce(l.status::text,''))='pending';
  if v_count=0 then raise exception 'No pending item loans were found for this client application.'; end if;

  if exists (
    select 1 from public.pb_loans l
    where l.order_id::text=p_order_id and l.member_id::text=p_member_id
      and lower(coalesce(l.status::text,''))='pending'
      and (l.asset_id is null or coalesce(l.asset_quantity,0)<=0)
  ) then raise exception 'Every item loan must be linked to inventory with a valid quantity.'; end if;

  if exists (
    select 1
    from public.pb_loans l
    where l.order_id::text=p_order_id and l.member_id::text=p_member_id
      and lower(coalesce(l.status::text,''))='pending'
    group by l.asset_id
    having count(*)>1
  ) then raise exception 'The same inventory item appears more than once for this client. Use one row and increase its quantity.'; end if;

  -- Lock and validate every required stock item before changing anything.
  for v_stock in
    select l.asset_id,sum(greatest(1,coalesce(l.asset_quantity,1)))::numeric as required_qty
    from public.pb_loans l
    where l.order_id::text=p_order_id and l.member_id::text=p_member_id
      and lower(coalesce(l.status::text,''))='pending'
    group by l.asset_id
  loop
    select i.* into v_asset
    from public.pb_inventory i
    where i.id::text=v_stock.asset_id::text
      and i.business_id::text=v_staff.business_id::text
    for update;
    if not found then raise exception 'A linked inventory item could not be found.'; end if;
    if coalesce(v_asset.stock,0)<v_stock.required_qty then
      raise exception 'Insufficient stock for %. Available %, required %.',v_asset.name,coalesce(v_asset.stock,0),v_stock.required_qty;
    end if;
  end loop;

  -- All checks passed. Deduct combined quantities once per item.
  for v_stock in
    select l.asset_id,sum(greatest(1,coalesce(l.asset_quantity,1)))::numeric as required_qty
    from public.pb_loans l
    where l.order_id::text=p_order_id and l.member_id::text=p_member_id
      and lower(coalesce(l.status::text,''))='pending'
    group by l.asset_id
  loop
    update public.pb_inventory i
    set stock=i.stock-v_stock.required_qty
    where i.id::text=v_stock.asset_id::text
    returning i.* into v_asset;
    v_stock_updates:=v_stock_updates||jsonb_build_array(jsonb_build_object(
      'asset_id',v_asset.id::text,'stock_remaining',v_asset.stock
    ));
  end loop;

  select coalesce(jsonb_agg(l.id::text),'[]'::jsonb) into v_loan_ids
  from public.pb_loans l
  where l.order_id::text=p_order_id and l.member_id::text=p_member_id
    and lower(coalesce(l.status::text,''))='pending';

  update public.pb_loans l
  set status='active'
  where l.order_id::text=p_order_id and l.member_id::text=p_member_id
    and lower(coalesce(l.status::text,''))='pending';

  if exists (
    select 1 from public.pb_loans l
    where l.order_id::text=p_order_id
      and lower(coalesce(l.status::text,''))='pending'
  ) then v_order_status:='pending'; else v_order_status:='fulfilled'; end if;

  update public.pb_orders
  set status=v_order_status,approved_by=v_staff.id
  where id::text=p_order_id;

  return jsonb_build_object(
    'approved_loan_ids',v_loan_ids,
    'approved_count',v_count,
    'stock_updates',v_stock_updates,
    'order_status',v_order_status
  );
end;
$$;

grant execute on function public.pb_approve_sold_items_loan_group(text,text) to authenticated;
revoke all on function public.pb_approve_sold_items_loan_group(text,text) from public,anon;

commit;

select
  'Wamama grouped Sold Items approvals and genuine multiple loans are ready' as result,
  (select count(*) from public.pb_loan_trigger_backup_20260821) as loan_rules_backed_up,
  (select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid
    where c.relname='pb_loans' and t.tgname='pb_block_exact_duplicate_active_loans_trigger'
      and not t.tgisinternal) as exact_duplicate_guards_active,
  false as existing_loans_changed,
  false as loan_balances_changed,
  false as repayments_changed,
  false as inventory_changed_during_setup;
