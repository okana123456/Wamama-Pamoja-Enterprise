# Incorrect loans with reversed repayment history

An unused-looking loan may still have reversed repayment rows. A KES 0 Paid
total excludes those rows from balances; it does not mean they can be erased.
The existing permanent-delete guard correctly protects this history.

On 26 September, a fresh authenticated Clintone session confirmed that Ivone
Awuor Ouma's Nyumba 30 gauge (x14) loan, ID
`9616a92c-61d5-4395-9468-e66081fc4497`, is active at KES 19,600, weekly KES 968.92,
with KES 0 paid. Its repayment history contains two voided zero-amount rows,
dated 18 and 25 September. The deletion check counts these retained rows.

Install `wamama-cancel-unused-loan.sql` in the Wamama database. Installation
changes no existing loan. The readiness query should return true. Refresh the
administrator portal, open Active Loans, choose the unwanted loan's three-dot
menu, select Cancel incorrect loan or Delete Loan, enter the reason and click
Remove loan. Delete unused duplicate uses the same operation. These choices
remove the loan from the active portfolio instead of erasing accounting history.

The 29 September report shows Ruth Auma Nyanywa with two active Kabati loans:
7 September, weekly KES 688.12, paid KES 688.12; and 9 September, weekly KES
651.20, paid KES 0. The screenshot contains no error message and does not
establish whether the unpaid loan has retained history or pending deposits.
Code review found that the older Delete Loan and Delete unused duplicate options
still attempted physical deletion and rejected any accounting history. All three
removal choices now invoke the same manager-only cancellation RPC and dialog.
The live database installation and Ruth's cancellation remain unconfirmed.

The server permits cancellation only for an active administrator, CEO or branch
manager in the loan's own business. It rechecks all dates, active/pending payment
amounts and principal/interest allocations, funded deposits, linked deposit
records and prepayment releases. Reversed/rejected/cancelled payment history
stays attached. Cancellation and its audit entry commit together. Accounting
write locks prevent a new payment from arriving between validation and commit.
No payment/deposit amount is transferred or erased by this operation.

The loan leaves the active portfolio, balances and arrears. The client refreshes
only that loan's authoritative financial snapshot and preserves the incremental
cache cursors. Repeated requests are idempotent. Server errors leave the client
record unchanged, and late responses cannot update a different signed-in account.

Run `node tests/cancel-unused-loan-ui.cjs` and, with PGLITE_MODULE configured,
`node tests/cancel-unused-loan-sql.cjs`. PostgreSQL tests cover history retention,
active/pending payments, deposit links, actor UUID types, roles, tenant isolation,
repeat calls, audit failure rollback and optional-table compatibility.

The specific production loan has not been cancelled by the developer session:
the supplied officer account cannot perform administrator cancellation.
