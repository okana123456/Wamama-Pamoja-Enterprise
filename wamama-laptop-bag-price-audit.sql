-- Read-only: inspect the laptop bag purchase and the inventory item it should update.
-- Run in the Wamama Supabase SQL Editor. This does not alter prices or stock.
with matching_inventory as (
  select i.*
  from public.pb_inventory i
  where lower(i.name) like '%laptop%'
    and lower(i.name) like '%bag%'
    and lower(i.name) like '%med%'
), matching_lines as (
  select pl.*, p.received_on, p.supplier_name
  from public.pb_purchase_lines pl
  join public.pb_purchases p on p.id = pl.purchase_id
  where pl.asset_id in (select id from matching_inventory)
     or (lower(pl.asset_name) like '%laptop%'
         and lower(pl.asset_name) like '%bag%'
         and lower(pl.asset_name) like '%med%')
)
select 'INVENTORY' as record_type, i.id as record_id,
  jsonb_build_object(
    'name', i.name, 'stock', i.stock,
    'actual_purchase_price', i.purchase_price,
    'inventory_cost_unit', i.buying_price,
    'loan_price_unit', i.loan_price,
    'cost_method', i.cost_method,
    'cost_adjustment', i.cost_adjustment,
    'created_at', to_jsonb(i)->'created_at', 'updated_at', to_jsonb(i)->'updated_at'
  ) as details
from matching_inventory i
union all
select 'PURCHASE_LINE', pl.id,
  jsonb_build_object(
    'asset_name', pl.asset_name, 'linked_asset_id', pl.asset_id,
    'purchase_id', pl.purchase_id, 'received_on', pl.received_on,
    'supplier', pl.supplier_name, 'quantity', pl.quantity,
    'supplier_price_unit', pl.cost_per_unit,
    'landed_adjustment_unit', pl.landed_adjustment,
    'subtotal', pl.subtotal
  )
from matching_lines pl
order by record_type, record_id;

-- Only an inference for a single most recent receipt, not a price correction.
-- The before-cost and before-loan-price are meaningful only if no other
-- receipts or manual edits occurred after this purchase.
select i.id as inventory_id, i.name, pl.id as purchase_line_id,
  pl.asset_id as linked_asset_id, p.received_on,
  i.stock as stock_now, pl.quantity as units_received,
  pl.cost_per_unit as supplier_price_unit,
  i.purchase_price as recorded_purchase_price_unit,
  i.buying_price as cost_unit_now,
  i.loan_price as loan_price_now,
  case when i.stock > pl.quantity then
    round((i.stock * i.buying_price - pl.quantity * (pl.cost_per_unit + coalesce(pl.landed_adjustment,0)))
      / (i.stock - pl.quantity),2)
  end as inferred_cost_before_receipt,
  case when i.stock > pl.quantity and i.buying_price > 0 then
    round(i.loan_price / i.buying_price *
      ((i.stock * i.buying_price - pl.quantity * (pl.cost_per_unit + coalesce(pl.landed_adjustment,0)))
        / (i.stock - pl.quantity)),2)
  end as inferred_loan_price_before_receipt
from public.pb_inventory i
join public.pb_purchase_lines pl on pl.asset_id = i.id
  or (pl.asset_id is null and lower(trim(pl.asset_name)) = lower(trim(i.name)))
join public.pb_purchases p on p.id = pl.purchase_id
where p.received_on = date '2026-10-05'
  and lower(i.name) like '%laptop%'
  and lower(i.name) like '%bag%'
  and lower(i.name) like '%med%'
order by pl.id;

-- Recent client orders can show the previously quoted loan price in notes.
-- They are evidence for review, not an instruction to overwrite today's price.
select o.id as order_id, o.ordered_on, o.status, o.asset_name, o.quantity,
  o.notes as quoted_asset_prices
from public.pb_orders o
where o.asset_id in (
  select i.id from public.pb_inventory i
  where lower(i.name) like '%laptop%'
    and lower(i.name) like '%bag%'
    and lower(i.name) like '%med%'
)
order by o.ordered_on desc nulls last, o.id desc
limit 10;
