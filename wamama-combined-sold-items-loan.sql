-- Run the complete file in the Wamama Supabase SQL Editor.
-- Adds support for new combined product loans. Existing records are unchanged.
begin;
alter table public.pb_loans add column if not exists sold_items jsonb;

create or replace function public.pb_validate_combined_sold_items()
returns trigger language plpgsql set search_path=pg_catalog,public,pg_temp as $$
declare item jsonb; asset public.pb_inventory%rowtype; principal numeric:=0; units numeric:=0; seen text[]:='{}';
begin
  if new.sold_items is null then return new; end if;
  if jsonb_typeof(new.sold_items)<>'array' or jsonb_array_length(new.sold_items)=0 then raise exception 'A combined loan requires product lines.'; end if;
  for item in select value from jsonb_array_elements(new.sold_items) loop
    if item->>'asset_id' is null or item->>'quantity' is null or item->>'principal' is null then raise exception 'Every product needs inventory, quantity and amount.'; end if;
    if item->>'asset_id'=any(seen) then raise exception 'Use one line per product and increase its quantity.'; end if;
    seen:=array_append(seen,item->>'asset_id');
    if (item->>'quantity')::numeric<=0 or (item->>'quantity')::numeric<>trunc((item->>'quantity')::numeric) or (item->>'principal')::numeric<=0 then raise exception 'Product quantities and amounts must be positive.'; end if;
    select i.* into asset from public.pb_inventory i where i.id::text=item->>'asset_id' and i.business_id::text=new.business_id::text;
    if not found then raise exception 'A product is not in this business inventory.'; end if;
    principal:=principal+(item->>'principal')::numeric; units:=units+(item->>'quantity')::numeric;
  end loop;
  if round(principal,2)<>round(new.loan_value::numeric,2) or units<>new.asset_quantity then raise exception 'Product totals must match the combined loan.'; end if;
  return new;
end;$$;
revoke all on function public.pb_validate_combined_sold_items() from public,anon,authenticated;
drop trigger if exists pb_validate_combined_sold_items_trigger on public.pb_loans;
create trigger pb_validate_combined_sold_items_trigger before insert or update of sold_items,loan_value,asset_quantity,business_id on public.pb_loans for each row execute function public.pb_validate_combined_sold_items();

create or replace function public.pb_approve_sold_items_loan_group(
  p_order_id text,
  p_member_id text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,pg_temp
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
      and (case when l.sold_items is not null then jsonb_typeof(l.sold_items)<>'array' or jsonb_array_length(l.sold_items)=0 else l.asset_id is null or coalesce(l.asset_quantity,0)<=0 end)
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
    select item->>'asset_id' as asset_id,sum((item->>'quantity')::numeric) as required_qty
    from public.pb_loans l
    cross join lateral jsonb_array_elements(coalesce(l.sold_items,jsonb_build_array(jsonb_build_object('asset_id',l.asset_id,'quantity',l.asset_quantity)))) item
    where l.order_id::text=p_order_id and l.member_id::text=p_member_id
      and l.business_id::text=v_staff.business_id::text
      and lower(coalesce(l.status::text,''))='pending'
    group by item->>'asset_id'
    order by item->>'asset_id'
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
    select item->>'asset_id' as asset_id,sum((item->>'quantity')::numeric) as required_qty
    from public.pb_loans l
    cross join lateral jsonb_array_elements(coalesce(l.sold_items,jsonb_build_array(jsonb_build_object('asset_id',l.asset_id,'quantity',l.asset_quantity)))) item
    where l.order_id::text=p_order_id and l.member_id::text=p_member_id
      and l.business_id::text=v_staff.business_id::text
      and lower(coalesce(l.status::text,''))='pending'
    group by item->>'asset_id'
    order by item->>'asset_id'
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

revoke all on function public.pb_approve_sold_items_loan_group(text,text) from public,anon;
grant execute on function public.pb_approve_sold_items_loan_group(text,text) to authenticated;
commit;
select 'Combined Sold Items loans ready; existing financial records unchanged' as result;
