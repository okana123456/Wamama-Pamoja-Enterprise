# Inventory cost and selling price

Run [wamama-inventory-cost-separation.sql](wamama-inventory-cost-separation.sql) once in the **Wamama** Supabase SQL Editor before using the new inventory form. The script is safe to rerun and ends with counts of supplier prices recorded and still needing review. It does not change existing inventory costs or loan prices.

To enforce management-only access, run [wamama-inventory-reference-price-access.sql](wamama-inventory-reference-price-access.sql) and then [wamama-inventory-reference-price-access-check.sql](wamama-inventory-reference-price-access-check.sql) in the same Wamama project. This removes direct browser access to the two confidential price columns, adds manager-only price functions, prevents officers from promoting their own role, and removes full inventory rows from Realtime broadcasts. Staff can refresh to see new stock quantities. The access migration preserves all existing prices and stock.

Previously, `pb_inventory.buying_price` was labelled “Cost/unit.” A supplier receipt replaced it with a weighted average of old stock cost and the new line cost. The same receipt also recalculated `loan_price` to preserve the prior markup; a new purchase item was automatically priced at 115% of its cost. Thus `buying_price` was **not a reliable record of the amount paid to the supplier**, and a stock receipt could change the client price.

The three fields are now separate:

| Field | Meaning | How it changes |
| --- | --- | --- |
| `purchase_price` ("Actual buying/wholesale price") | Management's confidential reference for the actual supplier price per unit | Set or corrected by an admin, CEO, or branch manager in Inventory; a procurement receipt cannot change it |
| `buying_price` ("Stock valuation cost/unit") | Current cost per unit used to value remaining stock | Set or recalculated by management in Inventory; a procurement receipt cannot change it |
| `loan_price` | Client selling/loan price per unit | Set separately by an admin, CEO, or branch manager; receipts never change it |

The Purchases page records a separate transaction `cost_per_unit` from the supplier invoice. Procurement enters this amount without seeing the confidential Inventory reference prices; choosing an asset never fills it from Inventory. Receiving stock increases quantity and records the purchase line, but does not revise the Inventory reference wholesale price, valuation cost, or loan price. Management must review the invoice and deliberately update the reference price and valuation cost when appropriate. A newly received item starts with a zero valuation cost and no selling price; management must price it before loan issuance. Staff who enter an invoice necessarily know the cost on that invoice, even though they cannot read or change the management-controlled Inventory reference.

The cost method is shown on the management Inventory form. **Weighted average** is `(old stock × old cost + received units × (supplier price + per-unit adjustment)) ÷ new stock`. **Latest purchase** uses `supplier price + per-unit adjustment`. **Manual** retains the cost entered by management. A positive adjustment adds transport or other landed cost; a negative one reflects a discount. Gross margin is `(loan price − reference supplier price) ÷ loan price`; cost margin uses valuation cost instead.

The setup script only backfills a supplier price where an older purchase line is linked to the inventory item. A blank supplier price on older items means it is **unknown**, not zero; staff should review supplier invoices and enter it. Historical loan issue costs were not stored when those loans were issued, so the Accounting page labels its historical issued-asset cost as an estimate based on current inventory cost. The new fields make current stock values and prospective margins clear, but do not retroactively establish exact historical profit.

Search input for groups, members, loans, and inventory now waits briefly for typing to pause before rebuilding a page. Member searches reuse derived account indexes while typing; loan searches use the current verified financial snapshot when available. This is a display-side change and does not add Supabase requests per keystroke.
