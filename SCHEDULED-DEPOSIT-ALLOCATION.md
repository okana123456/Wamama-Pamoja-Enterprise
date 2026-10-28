# Shared scheduled loan deposits

Install `wamama-shared-deposit-auto-allocation.sql` in the Wamama Supabase SQL Editor.
The script replaces the earlier release implementation, installs a private worker,
schedules `wamama-due-loan-deposits` every five minutes and performs an initial catch-up.
The final query returns Peres Akong'o's actual balances and whether the job is active.

Scheduled deposits are a shared client balance. They can cover due instalments on
another active loan belonging to the same client and business. Loans are processed
in start-date order. Amounts not yet due stay in deposits. Pre-loan product deposits
remain earmarked for funding; ordinary savings are not used.

The worker checks the source receipt, ignores unapproved/voided/future cash, checks
that release records do not exceed the released counter, and locks processing per business.
The counter can also include a valid early-close allocation recorded outside the
scheduled-release table; its unused remainder stays available.
Each new allocation records the source's prior released amount in `allocation_offset`.
This allows a later top-up to the same loan instalment while preventing duplicate
use of the same allocation position. Original cash receipts are unchanged. Generated
repayments are dated no earlier than receipt of their source money and remain marked
as internal releases so collection reports do not count them as new cash.

Collection-sheet exports await release processing, refresh loan figures and refresh
the deposit ledger/feed. An unsuccessful check blocks export rather than producing
a sheet with unverified deposit balances. The database job also runs when no user is
logged into the app. Its execution history is available in Supabase Cron.

The private worker has no API-role execute grants. The public RPC requires an active
staff session and derives the business from that session. Function search paths are
fixed. Setup is repeatable and retains the prior RPC definition in a private backup.

Regression coverage: `tests/shared-deposit-auto-allocation-sql.cjs` and
`tests/deposit-export-settlement.cjs`. The embedded SQL test simulates Cron scheduling;
successful scheduling and real job execution must also be checked in Supabase.
Job activation uses `cron.alter_job`, rather than direct writes to Supabase's
managed `cron.job` table.
