-- One-time Wamama safeguard for browser tabs running the old receipt code.
-- Safe to run again. It does not change stock, valuation cost or loan prices.
-- Run after wamama-inventory-cost-separation.sql.
begin;

create or replace function public.pb_keep_loan_price_on_legacy_receipt()
returns trigger
language plpgsql
as $$
begin
  -- The old app increased stock and recalculated both prices in one UPDATE,
  -- without recording purchase_price. Preserve management's loan price.
  -- A deliberate price-only edit remains possible in the Inventory form.
  if new.stock > old.stock
     and new.buying_price is distinct from old.buying_price
     and new.loan_price is distinct from old.loan_price
     and new.purchase_price is not distinct from old.purchase_price then
    new.loan_price := old.loan_price;
  end if;
  return new;
end;
$$;

drop trigger if exists pb_keep_loan_price_on_legacy_receipt on public.pb_inventory;
create trigger pb_keep_loan_price_on_legacy_receipt
before update on public.pb_inventory
for each row execute function public.pb_keep_loan_price_on_legacy_receipt();

-- A supplier purchase entered after the original migration may now be linked
-- to an item whose purchase_price was still unknown. Backfill only such rows;
-- never infer a supplier price from inventory cost or from a name alone.
with latest_linked_purchase as (
  select distinct on (pl.asset_id) pl.asset_id, pl.cost_per_unit
  from public.pb_purchase_lines pl
  join public.pb_purchases p on p.id=pl.purchase_id
  where pl.asset_id is not null and pl.cost_per_unit is not null
  order by pl.asset_id, p.received_on desc nulls last, p.id desc, pl.id desc
)
update public.pb_inventory i
set purchase_price=lp.cost_per_unit
from latest_linked_purchase lp
where i.id=lp.asset_id and i.purchase_price is null;

commit;

select
  (select count(*) from pg_trigger
   where tgname='pb_keep_loan_price_on_legacy_receipt'
     and tgrelid='public.pb_inventory'::regclass
     and not tgisinternal) as guard_triggers_installed,
  count(*) filter (where purchase_price is not null) as purchase_prices_recorded,
  count(*) filter (where purchase_price is null) as purchase_prices_to_review
from public.pb_inventory;
