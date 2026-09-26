# Financial reporting reconciliation

Application corrections prepared on 26 September 2026. Production data verification remains a separate required step.

## Confirmed defects in the previous source

- PIN switching changed `state.staff` without authenticating that account, refreshing its portfolio, or clearing the previous account's financial data.
- Approval-only refreshes advanced the complete-history cache cursor and full-sync timestamp, allowing approvals/voids on older repayments to be missed.
- The loan-closure check omitted `voided_at`; deployed repayment-sum functions could also count voided approved rows.
- Loan lists, officer filters and exports mixed historical loan officers with current group assignments.
- Arrears calculations and exports were duplicated. The next-due calculation skipped the first due date; overdue calculations used that same date as the first instalment.
- Backdated transactions could appear in both their payment-date period and their creation-date period.
- Scheduled deposit releases were counted as new cash; officers lacked direct access to the deposit ledger needed to recover the original cash amount.

These are verified code defects. The particular cause of each reported live discrepancy must be established by reconciliation against production records.

## Current rules

- `start_date` is the first repayment due date, matching the scheduled-prepayment ledger.
- A due date is payable throughout that Kenya calendar day. It becomes overdue the following day.
- Existing KES 5 arrears tolerance is retained. Only approved, unvoided repayments dated on or before the report date reduce balances.
- Outstanding principal and outstanding principal plus interest remain separate figures.
- Current group ownership defines portfolio balances/arrears. The recording officer defines collection performance. Management's selected officer uses the same respective definitions as that officer's dashboard.
- Original cash, the portion applied to a loan, and deposit releases are distinct. Deposit releases reduce a loan balance but are not a second cash collection.

## Rollout and live acceptance

1. Run `wamama-authoritative-financial-snapshot.sql` in project `hqxanetwkvmcfaaewnzl`. Both readiness flags must be true. It installs read-only reporting functions, an incremental lookup index, and corrects existing trigger sums to exclude voids. It does not rewrite historical loan/payment amounts or silently reopen completed loans.
2. Publish the accompanying application files, then refresh the website. Account switching now requires the target account's sign-in credentials.
3. Run `wamama-live-financial-reconciliation-check.sql`. Investigate any nonzero historical-status or schedule review counts individually.
4. Compare the same officer, Kenya report date and group scope in management reports, Due & Arrears, the arrears export, and the separately authenticated officer dashboard. Reconcile outstanding P+I, arrears count and arrears amount to the SQL result. Confirm collections use identical date ranges.
5. Observe a normal authorized payment/approval and confirm the officer and admin receive the change. Do not create a dummy production payment to test this.

## Data usage safeguards

Full history downloads retain the existing incremental cache. Five-minute active-page checks return changed loan summaries plus compact authorized loan IDs. Realtime events use debounced targeted refreshes. A mismatched cache is repaired for affected loans rather than redownloading all repayment history. Collection reporting returns grouped totals; the privileged function exposes only the authenticated staff member's business/role/team scope. Hidden tabs do not run periodic financial checks.

## Automated verification

Run `node tests/financial-consistency.cjs` for date boundaries, voids, ownership, export parity, cache-cursor preservation, targeted repairs and authenticated switching. Run `tests/financial-snapshot-sql.cjs` with `PGLITE_MODULE` pointing to an installed `@electric-sql/pglite` module for PostgreSQL installation/idempotency, JS/SQL parity, administrator/officer/supervisor parity, tenant isolation, restricted-deposit cash totals, scope removal and the live audit query.

Passing these tests does not substitute for production account reconciliation.
