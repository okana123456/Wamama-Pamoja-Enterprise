# Wamama Pamoja Enterprise - System Handover

This handover covers only the Wamama Pamoja Enterprise system. It intentionally excludes Radari, PrimeCredit, Prime Braidox, Bripta/Loanflow, and any other systems.

## 1. System Purpose and Users

Wamama Pamoja Enterprise is a group lending and savings management system used to run daily SACCO-style operations for member groups.

Primary users:

- Admin/manager: oversees the whole system, approvals, reports, permissions, and subscription status.
- Officers/field staff: record savings, repayments, client activity, and client orders when permitted.
- Approval staff: review and approve or reject savings and repayment entries.
- Members/clients: the people whose savings, loans, repayments, and group records are managed in the system.

The system is designed for daily operational use: recording member transactions, managing approvals, tracking active loans, handling group records, and keeping management reports fast enough for a growing business.

## 2. Technology Stack

- Frontend: single-page HTML, CSS, and JavaScript application in `index.html`.
- Backend: Supabase.
- Database: Supabase Postgres.
- Authentication/session handling: Supabase Auth.
- Server-side functions: Supabase Edge Functions.
- Payments: Safaricom Daraja/M-Pesa STK integration for monthly system subscription billing.
- Source control: GitHub.
- Deployment flow: GitHub Desktop is used locally, then the hosting platform pulls from the GitHub repository.

No raw API keys, passkeys, or secrets should be stored in this repository.

## 3. Repository Name and Branch

- GitHub repository: `okana123456/Wamama-Pamoja-Enterprise`
- Working branch: `main`
- Local working folder used in Codex: `C:\Users\Admin\Documents\Codex\2026-07-01\ho\work\wamama-pamoja-update`

## 4. Completed Features

- Added monthly admin subscription reminder and lock flow.
- Added Daraja STK push flow for monthly subscription payment.
- Fixed Daraja setup issue where the passkey secret was missing/undefined.
- Added a visible subscription reminder/payment overlay for admins.
- Added officer permission support for creating client orders.
- Added bulk duplicate rejection for Savings Approvals.
- Added bulk duplicate rejection for Repayment Approvals.
- Improved savings approval loading so high-volume pending approvals can be reviewed in pages instead of failing silently.
- Added performance indexes for faster login, client opening, transaction saving, report generation, and switching between modules.
- Repaired loan totals so the required 6 percent loan charge is included in active loan total payable/outstanding balances.
- Added SQL repair scripts so important database fixes can be rerun or reviewed safely.

## 5. Current Architecture

The system is currently a compact single-page application:

- `index.html` contains the user interface, Supabase client setup, navigation, permissions checks, approval screens, and most application logic.
- Supabase Postgres stores members, groups, loans, savings, repayments, approvals, order permissions, billing state, and related operational records.
- Supabase Edge Functions handle monthly billing payment requests and payment callbacks.
- SQL scripts in the repository are used to add permissions, improve indexes, and repair loan-charge balances.

Important architecture note: some Supabase Edge Function code was deployed directly through the Supabase dashboard during support work. For long-term maintainability, the Edge Function source should be added to the repository under a `supabase/functions` folder.

## 6. Database Structure and Important Business Rules

Important data areas:

- Groups: group names and group-level records.
- Members/clients: client identity, phone, group, status, savings, and loan relationship.
- Savings records: officer-recorded savings awaiting approval or already approved/rejected.
- Repayment records: loan repayments awaiting approval or already approved/rejected.
- Loans/active loans: principal, total payable, repayments, outstanding balances, and status.
- Orders/client orders: officer-created orders controlled by permissions.
- Staff/permissions: admin-controlled rights for officers.
- Billing records: monthly subscription state for the system lock/reminder.

Important business rules:

- Savings and repayment entries should be reviewed in approval tabs before being finalized.
- Duplicate pending savings and repayment records can be rejected in bulk from their approval screens.
- Officers should only create client orders if the admin has granted that permission.
- Active loan totals must include the required 6 percent charge.
- Repayments should reduce the full total payable, including the 6 percent charge.
- Monthly subscription payment must be completed for admin access to remain open.
- Database changes should be made through reviewed SQL scripts, not manual random edits.

## 7. Decisions Made and Reasons

- Duplicate entries are handled from approval screens instead of deleting silently, so the business keeps an audit-friendly review process.
- Order creation was added as a permission rather than giving officers full admin access, so the admin remains in control.
- Performance was improved with indexes and lighter approval loading instead of immediately depending on a paid Supabase upgrade.
- The 6 percent loan charge was repaired in the database because the client expects active loan totals to reflect the real repayable amount.
- Monthly subscription billing was implemented as an admin-facing reminder/lock because this system is maintained as a paid monthly service.
- Secrets are kept in Supabase Edge Function Secrets, not in frontend files or SQL scripts.

## 8. Known Bugs

No confirmed open Wamama bug remains from the latest support cycle.

Risks to watch:

- If data grows heavily on the Supabase free plan, speed may reduce again.
- Duplicate entries can still happen at the workflow level; the current fix makes them easier to reject in bulk.
- Edge Function source is not fully versioned in the repository yet, which can make future handover harder.

## 9. Unfinished Work

- Move all Wamama Edge Function source code into the repository.
- Add a clear `supabase/functions` folder with billing/payment function names matching the deployed Supabase functions.
- Add database-level duplicate-prevention rules where safe.
- Add audit logs for bulk duplicate rejection.
- Add a formal backup and restore process.
- Add a staging/testing Supabase project before future risky database changes.

## 10. Deployment Information

Normal deployment flow:

1. Edit files in the local Wamama repository.
2. Review changes in GitHub Desktop.
3. Commit to `main`.
4. Push to GitHub.
5. Let the connected hosting deployment update from GitHub.
6. Run any required SQL scripts in the Wamama Supabase SQL Editor.
7. Deploy or update any required Supabase Edge Functions in the Wamama Supabase project.
8. Confirm Edge Function Secrets are present before testing payment flows.

Required billing/payment secret names should be stored only in Supabase:

- `DARAJA_CONSUMER_KEY`
- `DARAJA_CONSUMER_SECRET`
- `DARAJA_PASSKEY`
- `DARAJA_SHORTCODE`
- `DARAJA_TRANSACTION_TYPE`
- `BILLING_AMOUNT`
- `BILLING_ACCOUNT_REFERENCE`
- `BILLING_DESCRIPTION`

Do not commit actual secret values to GitHub.

## 11. Files That Were Changed

Files currently present in the Wamama working repository:

- `index.html`
- `wamama-officer-order-permission.sql`
- `wamama-performance-indexes.sql`
- `wamama-fix-active-loan-6-percent-charge.sql`
- `README.md`

Main purpose of each support SQL file:

- `wamama-officer-order-permission.sql`: adds/supports the permission that allows officers to create client orders.
- `wamama-performance-indexes.sql`: improves database speed for common operational screens and reports.
- `wamama-fix-active-loan-6-percent-charge.sql`: repairs active loan totals so the 6 percent charge is included correctly.

## 12. Next Recommended Tasks

- Add Edge Function source files into GitHub so another developer can redeploy without searching Supabase manually.
- Add a short admin guide for approving savings, approving repayments, and rejecting duplicates.
- Add database constraints or duplicate checks before insert, where they will not block valid same-day entries.
- Add a simple monthly maintenance checklist: check pending approvals, check rejected duplicates, check Supabase database size, and verify billing lock status.
- Monitor performance as the business grows; if usage becomes heavy, consider moving the Wamama Supabase project to a paid plan.
- Add automated backups before running future repair SQL.
