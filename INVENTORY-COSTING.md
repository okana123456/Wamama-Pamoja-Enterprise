# Inventory cost and selling price

Run [wamama-inventory-cost-separation.sql](wamama-inventory-cost-separation.sql) once in the **Wamama** Supabase SQL Editor before using the new inventory form. The script is safe to rerun and ends with counts of supplier prices recorded and still needing review. It does not change existing inventory costs or loan prices.

Previously, `pb_inventory.buying_price` was labelled “Cost/unit.” A supplier receipt replaced it with a weighted average of old stock cost and the new line cost. The same receipt also recalculated `loan_price` to preserve the prior markup; a new purchase item was automatically priced at 115% of its cost. Thus `buying_price` was **not a reliable record of the amount paid to the supplier**, and a stock receipt could change the client price.

The three fields are now separate:

| Field | Meaning | How it changes |
| --- | --- | --- |
| `purchase_price` | Last actual supplier price per unit, excluding separately entered transport or discount | Entered on a supplier receipt or corrected in Inventory |
| `buying_price` (“Cost/unit”) | Current cost per unit used to value remaining stock | Calculated by the chosen method or entered manually |
| `loan_price` | Client selling/loan price per unit | Set separately by an admin, CEO, or branch manager; receipts never change it |

The cost method is shown on the Inventory form. **Weighted average** is `(old stock × old cost + received units × (supplier price + per-unit adjustment)) ÷ new stock`. **Latest purchase** uses `supplier price + per-unit adjustment`. **Manual** retains the cost entered by staff. A positive adjustment adds transport or other landed cost; a negative one reflects a discount. Editing the supplier price alone does not revalue existing weighted-average or manual stock. Gross margin is `(loan price − supplier price) ÷ loan price`; cost margin uses Cost/unit instead. New receipt items start without a selling price and cannot be issued until management sets one.

The setup script only backfills a supplier price where an older purchase line is linked to the inventory item. A blank supplier price on older items means it is **unknown**, not zero; staff should review supplier invoices and enter it. Historical loan issue costs were not stored when those loans were issued, so the Accounting page labels its historical issued-asset cost as an estimate based on current inventory cost. The new fields make current stock values and prospective margins clear, but do not retroactively establish exact historical profit.

Search input for groups, members, loans, and inventory now waits briefly for typing to pause before rebuilding a page. Member searches reuse derived account indexes while typing; loan searches use the current verified financial snapshot when available. This is a display-side change and does not add Supabase requests per keystroke.
