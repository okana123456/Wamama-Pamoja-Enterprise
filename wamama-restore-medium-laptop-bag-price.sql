-- Run only after management confirms KES 1,650 is the intended CURRENT
-- selling/loan price for this item. This changes no issued loans, stock,
-- purchase records, supplier price, or inventory cost.
begin;

do $$
declare
  v_inventory_id uuid := 'b87d8c14-e6cc-43fe-bd96-629b0321a477';
  v_old_price numeric(14,2);
  v_new_price numeric(14,2) := 1650.00;
  v_rows integer;
begin
  select i.loan_price into v_old_price
  from public.pb_inventory i
  where i.id=v_inventory_id
    and i.name='LAPTOP BAG MEDUIM'
    and i.stock=20
    and i.purchase_price=1500.00
    and i.buying_price=1540.00
    and i.cost_method='weighted_average'
  for update;
  if not found or v_old_price <> 1588.13 then
    raise exception 'Inventory values changed; no price correction was made.';
  end if;

  if not exists (
    select 1
    from public.pb_purchase_lines pl
    join public.pb_purchases p on p.id=pl.purchase_id
    where pl.id='a2e85206-2787-439c-b00d-1f91844f3df9'::uuid
      and pl.asset_id=v_inventory_id
      and pl.quantity=12
      and pl.cost_per_unit=1500.00
      and coalesce(pl.landed_adjustment,0)=0
      and p.received_on=date '2026-10-05'
      and p.supplier_name='Violet Traders'
  ) then
    raise exception 'The linked purchase changed; no price correction was made.';
  end if;

  update public.pb_inventory
  set loan_price=v_new_price
  where id=v_inventory_id;
  get diagnostics v_rows=row_count;
  if v_rows<>1 then
    raise exception 'Expected one inventory row; no price correction was made.';
  end if;
  raise notice 'Loan price restored from KES % to KES % for inventory item %',
    v_old_price,v_new_price,v_inventory_id;
end;
$$;

commit;

select id,name,stock,purchase_price as actual_supplier_price,
       buying_price as inventory_cost_unit,loan_price as selling_loan_price
from public.pb_inventory
where id='b87d8c14-e6cc-43fe-bd96-629b0321a477'::uuid;
