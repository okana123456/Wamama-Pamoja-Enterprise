# Combined Sold Items client loans

Run `wamama-combined-sold-items-loan.sql` in the Wamama Supabase SQL Editor before saving a new form, then refresh the app.

Select a client and first product. Use **Add item for this client** for each further product. Each line retains its inventory link, quantity and principal. The shared term is edited on the first product line. The client summary shows one combined principal, total payable and weekly installment. New forms create one pending loan per client; approval checks and deducts every product together. The preview and Excel export retain the product breakdown.

Existing loans, balances, repayments and stock quantities are not migrated or recalculated by this setup. Loans taken on separate forms remain separate. Submitted combined forms are read-only to avoid changing product allocations after stock approval.

Validation: combined-loan save/schedule and product reports; PostgreSQL approval for multi-product and legacy loans, insufficient-stock rollback, repeated approval, invalid totals and foreign inventory rejection; financial, pricing and collection-sheet regressions.
