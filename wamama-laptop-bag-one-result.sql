-- Read-only. One result table for the medium laptop bag incident.
-- Paste the complete result table back; no values are changed.
select
  i.id as inventory_id,
  i.name as inventory_name,
  i.stock,
  i.purchase_price as recorded_supplier_price,
  i.buying_price as inventory_cost_unit,
  i.loan_price as current_loan_price,
  i.cost_method,
  pl.id as purchase_line_id,
  pl.asset_id as purchase_linked_asset_id,
  pl.asset_name as purchase_asset_name,
  pl.received_on,
  pl.supplier_name,
  pl.quantity as purchased_units,
  pl.cost_per_unit as supplier_price_unit,
  pl.landed_adjustment as adjustment_unit,
  case when i.stock > pl.quantity then
    round((i.stock*i.buying_price - pl.quantity*(pl.cost_per_unit+coalesce(pl.landed_adjustment,0)))
      /(i.stock-pl.quantity),2)
  end as inferred_cost_before_receipt,
  case when i.stock > pl.quantity and i.buying_price > 0 then
    round((i.loan_price/i.buying_price)*
      ((i.stock*i.buying_price - pl.quantity*(pl.cost_per_unit+coalesce(pl.landed_adjustment,0)))
        /(i.stock-pl.quantity)),2)
  end as inferred_loan_price_before_receipt,
  (select count(*) from pg_trigger t
   where t.tgname='pb_keep_loan_price_on_legacy_receipt'
     and t.tgrelid='public.pb_inventory'::regclass
     and not t.tgisinternal) as safeguard_installed
from public.pb_inventory i
left join lateral (
  select line.*, purchase.received_on, purchase.supplier_name
  from public.pb_purchase_lines line
  join public.pb_purchases purchase on purchase.id=line.purchase_id
  where line.asset_id=i.id
     or (lower(line.asset_name) like '%laptop%'
         and lower(line.asset_name) like '%bag%'
         and lower(line.asset_name) like '%med%')
  order by purchase.received_on desc nulls last, line.id desc
  limit 5
) pl on true
where i.id='b87d8c14-e6cc-43fe-bd96-629b0321a477'::uuid;
