# Management goods returns and loan cancellation

Install `wamama-loan-return-settlement.sql` in the Wamama Supabase SQL Editor. Installation does not change any existing loan.

Active admins, CEOs and branch managers can use the loan action **Return goods and settle/cancel loan**. It checks the confirmed repayment balance, unused deposits attached to that loan and any funding deposit used when issuing. Management must split this total into refund, retained agreed charge and client product deposit. An actual refund requires its payment reference and records an `Other` expense with a goods-return description. Client credit is recorded as a product deposit with original cash received zero; it is a movement of existing funds. Pending repayments must be approved/rejected before settlement.

Management selects actual usable goods returned and quantities to restock. Zero means no stock recovery. Legacy combined product names can be mapped manually to inventory. Stock selection is therefore a management assertion rather than automatic proof that an item was returned. Pending loans cannot restock goods which have not been issued.

The operation locks the loan, cash and deposit state, completes all stock/cash/deposit/cancellation writes in one transaction, and retains the original repayments. A private settlement and public audit record retain the reason, actor, refund reference, amounts and stock choices. Already-settled loans return the recorded outcome without repeating changes. The loan remains in history with a cancelled status and dated settlement; current dues and outstanding balance are zero. Before that settlement date, historical metrics are preserved.

Savings and unrelated member deposits are untouched. This does not perform an external refund or transfer money through a payment provider: management must enter a reference for a refund already paid. No existing loan is automatically cancelled.
