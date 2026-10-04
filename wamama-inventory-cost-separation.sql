-- One-time Wamama inventory setup. Safe to run again.
-- Existing loan/selling prices and valuation costs are not changed.
begin;

alter table public.pb_inventory
  add column if not exists purchase_price numeric(14,2),
  add column if not exists cost_method text not null default 'weighted_average',
  add column if not exists cost_adjustment numeric(14,2) not null default 0;

alter table public.pb_purchase_lines
  add column if not exists landed_adjustment numeric(14,2) not null default 0;

do $$
begin
  if not exists(select 1 from pg_constraint where conname='pb_inventory_cost_method_check' and conrelid='public.pb_inventory'::regclass) then
    alter table public.pb_inventory add constraint pb_inventory_cost_method_check
      check (cost_method in ('weighted_average','latest_purchase','manual'));
  end if;
  if not exists(select 1 from pg_constraint where conname='pb_inventory_purchase_price_check' and conrelid='public.pb_inventory'::regclass) then
    alter table public.pb_inventory add constraint pb_inventory_purchase_price_check
      check (purchase_price is null or purchase_price >= 0);
  end if;
end;
$$;

-- Only a purchase line linked by asset ID identifies a historical supplier price.
-- Unlinked or ambiguous old stock keeps purchase_price NULL for manual review.
with latest_purchase as (
  select distinct on (pl.asset_id) pl.asset_id, pl.cost_per_unit
  from public.pb_purchase_lines pl
  join public.pb_purchases p on p.id = pl.purchase_id
  where pl.asset_id is not null and pl.cost_per_unit is not null
  order by pl.asset_id, p.received_on desc nulls last, p.id desc, pl.id desc
)
update public.pb_inventory i
set purchase_price = lp.cost_per_unit
from latest_purchase lp
where i.id = lp.asset_id and i.purchase_price is null;

commit;

select
  count(*) filter (where purchase_price is not null) as purchase_prices_recorded,
  count(*) filter (where purchase_price is null) as purchase_prices_to_review,
  count(*) filter (where cost_method not in ('weighted_average','latest_purchase','manual')) as invalid_cost_methods
from public.pb_inventory;
