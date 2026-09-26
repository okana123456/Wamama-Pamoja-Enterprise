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

## Live checks on 26 September 2026

The supplied database audit confirms that both reporting functions are installed.
Separately authenticated browser checks matched these arrears counts and amounts
on both the officer dashboard and Due & Arrears:

| Officer | Active loans | Arrears loans | Arrears KES | Database outstanding P+I KES |
| --- | ---: | ---: | ---: | ---: |
| Carlix Ogolla | 103 | 23 | 5,397.11 | 239,417.81 |
| Clintone Omondi otieno | 358 | 1 | 1,932.84 | 1,737,160.30 |
| Laureen Achieng Odera | 267 | 55 | 22,591.46 | 1,573,972.44 |

Carlix's already-open page used the older PIN-switch interface and showed only
one arrears loan (KES 51). Opening the newly deployed page changed it to 23 loans
and KES 5,397.11, matching the database. This confirms that an open page can
continue running the previous calculation until the website itself is reloaded.

Live checks also exposed a fractional-cent discrepancy: the officer dashboard
summed unrounded legacy loan totals while management and the SQL audit summed
rounded per-loan balances. Clintone's dashboard differed by KES 0.02 and
Laureen's by KES 0.01. All balance displays now use the shared per-loan financial
metrics, including the officer dashboard, meeting recorder and member profiles.
A regression verifies that summing fractional legacy totals cannot diverge.

The supplied audit flagged 42 completed loans with remaining balances: Clintone
12, Laureen 10, Sammy 18, Yvonne 2. `wamama-completed-loan-review.sql` is a
read-only diagnostic for those records. They have not been silently reopened or
adjusted. Management UI checks and the historical closure review remain pending.

The supplied loan-level review contains all 42 records, with an aggregate recorded
shortfall of KES 128,592.02. Twenty-one have zero valid paid amounts and twenty-one
have partial payments. All 42 have zero voided rows and zero future-dated payment
amounts, so those explanations do not account for this set. These figures are
recorded ledger gaps, not confirmed customer debts. The follow-up
`wamama-completed-loan-history-check.sql` checks possible same-asset replacement
loans, pending deposits and the latest loan audit events without changing data.
