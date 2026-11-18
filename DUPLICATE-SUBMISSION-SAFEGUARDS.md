# Duplicate-submission safeguards and login loading

Release `20261118-idempotent-submissions`. Code-only document: no client data.

## What changed

### Every financial submission has a stable operation ID
- **Meetings** (`submitMeeting`): before the first request the browser builds the whole
  meeting, gives the meeting and each saving/repayment its own UUID, and stores it in an
  on-device *outbox* (`localStorage`, key scoped to business **and** staff account). The
  form is then cleared so the same money cannot be typed in and submitted twice.
- **Standalone repayment dialog**: one UUID per dialog; pressing Save again after a
  timeout re-checks the same operation instead of recording a new payment.
- Timeouts, lost responses, reloads, reconnection and app updates re-send the **same**
  IDs. Only entries not yet confirmed are re-sent.

### The database enforces it
`wamama-financial-operation-idempotency.sql` (additive, re-runnable):
- `client_operation_id` / `client_operation_hash` on `pb_meetings`, `pb_savings`,
  `pb_repayments`, with partial unique indexes on `(business_id, client_operation_id)`.
- `pb_submit_meeting(jsonb)`: one request per meeting. Per entry it returns `created`,
  `existing` (a retry: the saved row is returned, nothing inserted) or `failed`.
  A failed entry never undoes or repeats the others (partial success is safe).
- Reusing an ID with different money returns `OPERATION_MISMATCH` instead of merging.
- `pb_record_repayments_batch` keeps its contract; rows that carry an ID become idempotent.
- The 30-second guard skips rows that carry an ID (exact dedupe), so two genuinely separate
  same-amount payments are accepted. Older browsers keep the old behaviour.
- The repeated-meeting receipt/saving guards installed on 18 Nov 2026 stay in place as a
  second line of defence (e.g. a device whose storage was cleared).
- Status (approved/pending) is decided by the server from the staff role, as before.
- One loan deposit per repayment is already enforced by
  `pb_excess_payments_original_repayment_uidx`; one repayment per operation therefore
  means one cash recognition and one allocation per operation.

### No overlapping sends
- One send at a time per account across all tabs (Web Locks; storage-lease fallback).
- Each outbox entry is updated individually against the latest stored list, so one tab
  never overwrites another tab's entries (the old queue rewrote the whole list after a
  long flush).
- Submit button shows *Saving…* and is single-flight; approval requests never overlap
  within a tab, and the database only moves rows that are still `pending`.
- A meeting with an unsent submission on the device cannot be submitted again until it is
  retried or discarded.
- The Weekly meeting page shows each submission as *Waiting to send*, *Sending…* or
  *Needs attention*, with *Retry now* / *Discard unsent entries*.

### Pre-update offline queue
Entries left by the previous version (`pb_<business>_queue`, no IDs) are **never sent
automatically**. Entries recorded by the signed-in staff member are de-duplicated and moved
into the outbox as *Needs attention* with a warning to check statements first; entries of
other staff members are left untouched.

### Loading
- Pinned `@supabase/supabase-js@2.119.0` (immutable one-year CDN cache instead of a
  floating `@2` that can change under the app).
- `index.html` is `no-cache` instead of `no-store`: every visit still revalidates (updates
  are not delayed) but an unchanged page is a ~0 KB 304 instead of ~182 KB.
- Keyset pagination for full table syncs (no `OFFSET` rescans; rows inserted during a long
  download can no longer shift pages and be skipped). The silent 50,000-row cut-off is
  replaced by an explicit error, so totals are never computed from a truncated history.
- With a local cache, history deltas download alongside core tables, and the server
  financial snapshot is requested at the start of loading instead of after all history.
  On a first (cold) load, core tables still go first.
- **Server-first dashboard.** As soon as the core tables (loans, groups, members, staff)
  and the server snapshot + collection totals arrive, the admin and officer dashboards
  show loan balances, arrears, collections, members, groups and loans issued, under a
  notice saying they are server totals as of a time. Savings-based figures (savings
  collected, loan eligibility, recent savings, per-group savings, pending approvals) show
  *Verifying…* — never a number or zero — until the full ledger has loaded and been
  reconciled. Server figures are not shown if any visible loan is missing locally, if the
  snapshot is not for today, or after a failed request (the retry state is shown instead).
  The same server sources feed the verified view, so those cards do not change on
  verification. Other pages still wait for verified figures.
  Modelled (`perf/startup-network-model.cjs`, real-time): first login on a new device,
  5 Mbps / 250 ms → server figures 2.2 s (previously nothing until ~25 s);
  20 Mbps / 120 ms → 1.1 s. Repeat logins: verified 1.9 s / 1.6 s.

## Tests
```
set PGLITE_MODULE=<path to @electric-sql/pglite>
node tests/financial-operation-idempotency-sql.cjs
node tests/financial-outbox-client.cjs
node tests/server-first-dashboard.cjs
```
All `tests/*.cjs` (38) pass. Performance models: `perf/startup-network-model.cjs`,
`perf/offset-vs-keyset-pglite.cjs`.

## Deployment order
1. Owner runs `wamama-production-safeguards-check.sql` (read-only) and keeps the JSON.
2. Owner runs `wamama-financial-operation-idempotency.sql`. Existing browsers keep working.
3. Owner re-runs the check: `pb_submit_meeting` present, `authenticated_can_execute`
   true / `anon_can_execute` false, three `*_business_operation_uidx` indexes present,
   `constraint_violations` = 0.
4. Deploy the web app (merge to `main`; Vercel builds). If the app is deployed before step
   2, meeting submissions are kept on the device with a "server needs the update" notice
   and sent automatically once the SQL is installed; nothing falls back to the old path.
5. Confirm `/release.json` shows `20261118-idempotent-submissions`, then record one
   meeting in a test group and press Retry/refresh: the counts must not change.

## Rollback
- Web app: promote the previous Vercel deployment. Submissions waiting in the new outbox
  stay on the device untouched and are sent when the new release returns.
- Database: the migration is additive and compatible with the previous web app. If needed,
  re-run `wamama-repayment-reliability-and-speed.sql` and
  `wamama-repayment-workflow-safety.sql` to restore the previous function bodies. Do not
  drop the new columns (they document which rows came from which operation).
