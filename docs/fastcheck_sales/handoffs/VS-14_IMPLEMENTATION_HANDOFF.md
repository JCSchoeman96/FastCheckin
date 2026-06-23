# VS-14 Implementation Handoff

## Status

Merged.

PR: #392 — feat(sales): VS-14 checkout expiry and hold cleanup  
Merge commit: `0d89b4940925bb890f7d3ccdc7b194dd7653e3f2`  
Implementation head: `a24841729bdb6a9b51de80325b7ea99ff96f17c5`  
Merged at: 2026-06-23T19:49:00Z  
Branch: `vs-14-checkout-expiry-and-cleanup`  
CI: run 875 green on implementation head

## What Changed

VS-14 added automated checkout session expiry and Redis hold cleanup for stale
unpaid checkouts. `FastCheck.Sales.CheckoutExpiry` is the sole service boundary
for candidate discovery, per-session expiry, order-level advisory locking,
hold release, durable Ash transitions, and hold-anomaly routing.

A cron sweeper (`CheckoutExpirySweeperWorker`, every 2 minutes) performs bounded
discovery and enqueues one `CheckoutExpiryWorker` job per eligible session on the
new `:sales_maintenance` Oban queue. Inventory cleanup uses
`ReservationLedger.release/3` only, with idempotency key
`checkout_expiry:release:<session_id>`.

Expiry skips sessions with verified payments, ticket issues, attendees, or
terminal/manual-review states. Corrupted hold facts on held sweeper statuses
route to `manual_review` with reason `checkout_expiry_hold_state_mismatch`
(including completely missing hold facts and `:already_consumed` ledger
outcomes). Retryable Redis/ledger errors fail closed via transaction rollback
and Oban retry.

No TicketIssue, Attendee, mobile/scanner, Paystack HTTP, WhatsApp, delivery, or
`event_sync_version` changes were made.

Planning context (not implementation truth):
`docs/fastcheck_sales/feature_packs/0034_VS-14_checkout-expiry-and-cleanup/VS-14-FEATURE_PACK.md`.

## Files Changed

- `lib/fastcheck/sales/checkout_expiry.ex` — authoritative expiry boundary;
  `list_expiry_candidates/1`, `sweep_and_enqueue/1`, `expire_session/2`;
  `pg_advisory_xact_lock(order.id)` + reload; `ReservationLedger.release/3`
  outcome matrix; telemetry for sweeper/worker/skip/expired/released/manual_review.
- `lib/fastcheck/workers/checkout_expiry_sweeper_worker.ex` — Oban cron worker;
  enqueue-only; delegates to `CheckoutExpiry.sweep_and_enqueue/1`.
- `lib/fastcheck/workers/checkout_expiry_worker.ex` — per-session Oban worker;
  Oban uniqueness on `checkout_session_id`; delegates to
  `CheckoutExpiry.expire_session/2`; no direct inventory/payment/ticket calls.
- `priv/repo/migrations/20260623120000_add_checkout_expiry_sweeper_index.exs` —
  partial index `sales_checkout_sessions_expiry_sweep_idx` on
  `(expires_at, id)` for `hold_attached` / `payment_link_sent` /
  `payment_started` where `expired_at IS NULL`.
- `config/config.exs` — `:sales_maintenance` Oban queue (concurrency 3); cron
  `*/2 * * * *` for sweeper; `:sales_checkout_expiry_sweep_batch_size` default 200.
- `test/fastcheck/sales/checkout_expiry_test.exs` — domain expiry, sweeper
  enqueue, release/idempotency, ledger errors, payment safety, hold anomalies,
  race with payment verification, PII-safe logs, `event_sync_version` unchanged.
- `test/fastcheck/workers/checkout_expiry_sweeper_worker_test.exs` — sweeper
  delegates to `CheckoutExpiry`; no direct mutation imports.
- `test/fastcheck/workers/checkout_expiry_worker_test.exs` — worker uniqueness,
  delegation boundary, missing session error, unknown release error without crash.
- `test/fastcheck/sales/checkout_inventory_boundary_test.exs` — asserts
  `checkout_expiry.ex` calls `ReservationLedger.release` only (no `Redix.command`).
- `test/fastcheck/sales/domain_shell_test.exs`, `vs_01f_boundary_test.exs`,
  `vs_01g_index_and_migration_verification_test.exs` — allowlist/index updates only.

## Contracts Now Available

- `FastCheck.Sales.CheckoutExpiry` — authoritative automated expiry entrypoint.
  Public functions:
  - `list_expiry_candidates/1` — bounded ids for sessions in
    `hold_attached` / `payment_link_sent` / `payment_started` past `expires_at`
    with `expired_at IS NULL`.
  - `sweep_and_enqueue/1` — discovers candidates and enqueues
    `CheckoutExpiryWorker` jobs; returns `%{enqueued, candidate_count}`.
  - `expire_session/2` — `{:ok, atom()}` or `{:error, term()}`; outcomes
    include `:expired`, `:manual_review`, skip reasons (`:skipped_terminal`,
    `:skipped_verified`, etc.), and retryable errors (`:ledger_unavailable`, etc.).
- Oban workers:
  - `FastCheck.Workers.CheckoutExpirySweeperWorker` — `:sales_maintenance`,
    cron every 2 minutes, sweeper uniqueness 120s.
  - `FastCheck.Workers.CheckoutExpiryWorker` — `:sales_maintenance`,
    max 8 attempts, uniqueness on `checkout_session_id` (300s).
- Index: `sales_checkout_sessions_expiry_sweep_idx` for sweeper query shape.
- Redis release idempotency: `"checkout_expiry:release:#{session_id}"`.
- Test hook: `:checkout_expiry_release_fun` (3-arity) overrides
  `ReservationLedger.release/3` in tests only.
- Hold anomaly reason code: `checkout_expiry_hold_state_mismatch` (routes order
  and session to `manual_review` via existing Ash actions).
- Telemetry events under `[:fastcheck, :sales, :checkout_expiry, *]`:
  `:sweeper_started`, `:worker_started`, `:skipped`, `:expired`, `:released`,
  `:manual_review`, `:failed`.

## Decisions Applied

- Order-level `pg_advisory_xact_lock(order.id)` with reload-after-lock, aligned
  with payment verification race semantics.
- Sweeper statuses consistently include `hold_attached`, `payment_link_sent`, and
  `payment_started` in query, partial index, and tests.
- Redis inventory mutation only through `ReservationLedger.release/3`; workers
  do not call ledger or Redix directly.
- Release outcomes: `{:ok, _}`, `:already_released`, `:hold_expired` proceed to
  durable expiry; `:hold_not_found` and `:already_consumed` → manual review;
  retryable ledger atoms and unknown `{:error, reason, _}` → fail closed (Oban retry).
- Held-status sessions with missing/corrupted hold facts → `manual_review`, not
  silent `expired_no_hold`.
- Skip expiry when `verified_success` payment, ticket issue, or attendee exists.
- `event_scoped_first`; `organization_id` deferred.
- No workflow actions; Ash named updates (`:expire_session`, `:expire_order`,
  `:mark_manual_review`) on existing resources.

## Boundaries Still Enforced

- No ticket issuance (`TicketIssue`, `Issuer.issue_order/2`) from expiry paths.
- No Attendee creation or mutation.
- No scanner/mobile sync controller or DTO changes.
- No Android changes.
- No Paystack HTTP, webhook handling, or payment verification calls from expiry.
- No WhatsApp/Meta, delivery, email, or customer notification.
- No refund or revocation execution.
- No direct Redis key mutation outside `ReservationLedger`.
- No `event_sync_version` bumps from expiry.
- No new operator UI; expiry anomalies surface via `manual_review` for VS-13
  `ManualReview` queue (no new dashboard page in this slice).
- No `StateTransition` audit rows appended by `CheckoutExpiry` (deferred).

## Tests Added Or Updated

- `test/fastcheck/sales/checkout_expiry_test.exs` — candidate listing;
  sweeper enqueue; happy-path release + durable expiry; duplicate idempotency;
  `:already_released` / `:hold_expired` proceed; `:ledger_unavailable` no expire;
  verified-payment skip; post-expiry payment verification safety; verification
  wins race; hold anomalies (cleared key, missing facts); `:already_consumed` and
  unknown release errors; advisory-lock source contract; log redaction;
  sweeper worker integration; no `event_sync_version` change.
- `test/fastcheck/workers/checkout_expiry_sweeper_worker_test.exs` — delegation
  and no forbidden imports.
- `test/fastcheck/workers/checkout_expiry_worker_test.exs` — uniqueness,
  delegation, missing session, unknown release error without crash.
- `test/fastcheck/sales/checkout_inventory_boundary_test.exs` — ledger-only
  inventory boundary for `checkout_expiry.ex`.
- Boundary/shell/index tests updated for new modules and migration.

## Verification Reported

From PR #392 / CI run 875 on head `a24841729bdb6a9b51de80325b7ea99ff96f17c5`:

```bash
mix test test/fastcheck/sales/checkout_expiry_test.exs test/fastcheck/workers/checkout_expiry_*
mix test test/fastcheck/sales/payments/ test/fastcheck/sales/inventory/
mix test test/fastcheck_web/controllers/mobile/sync_controller_test.exs test/fastcheck/attendees/
mix precommit
```

Results reported at merge:

- targeted checkout expiry domain + worker tests — pass (24 tests)
- broader Sales payment/inventory/mobile/attendee regression set — pass
- `mix precommit` — pass (864 tests, 0 failures)
- CI run 875 — green

## Known Limitations

- No dedicated expiry outcome UI; operators rely on VS-13 manual review for
  `checkout_expiry_hold_state_mismatch` cases.
- No `StateTransition` audit append from expiry service (feature pack mentioned
  it; not implemented in merged code).
- No customer-facing expiry notification.
- No refund, revocation, or delivery behavior.
- Sweeper batch size is config-driven (default 200); very large backlogs need
  repeated cron cycles.
- No dedicated slice doc under `docs/fastcheck_sales/slices/`; feature pack is
  planning context only.

## Next Agent Guidance

**Reuse:**

- `FastCheck.Sales.CheckoutExpiry` for all automated expiry and hold-release
  mutations; do not add expiry logic to LiveViews, payment modules, or workers
  beyond thin Oban delegation.
- `CheckoutExpirySweeperWorker` + `CheckoutExpiryWorker` as the only enqueue/
  perform path for scheduled expiry.
- `ReservationLedger.release/3` (via `CheckoutExpiry` only) for hold cleanup;
  preserve release idempotency key format.
- Existing Ash actions `:expire_session`, `:expire_order`, `:mark_manual_review`
  on `CheckoutSession` and `Order`.
- `FastCheck.Sales.ManualReview` (VS-13) for operator handling of
  `checkout_expiry_hold_state_mismatch` queue rows.
- Test hook `:checkout_expiry_release_fun` for ledger outcome tests.

**Do not:**

- Call `Redix.command` or write inventory keys from expiry or worker modules.
- Expire sessions with verified payments, ticket issues, or attendees present.
- Treat missing hold facts on held sweeper statuses as clean no-hold expiry.
- Bump `event_sync_version` from expiry cleanup.
- Add Paystack, issuance, delivery, or scanner changes inside expiry work.
- Bypass order-level advisory lock when coordinating with payment verification.

**Keep green:**

- `test/fastcheck/sales/checkout_expiry_test.exs`
- `test/fastcheck/workers/checkout_expiry_sweeper_worker_test.exs`
- `test/fastcheck/workers/checkout_expiry_worker_test.exs`
- `test/fastcheck/sales/checkout_inventory_boundary_test.exs`
- `test/fastcheck/sales/payments/`
- `test/fastcheck/sales/inventory/`
- `test/fastcheck_web/controllers/mobile/sync_controller_test.exs`
- `test/fastcheck/attendees/`
- `mix precommit`

## Next Slice

Recommended next slice: **VS-15A — Core Revocation and Scanner Visibility**

Entry condition:

- VS-14 is merged on `main`.
- Automated checkout expiry and hold cleanup run via `CheckoutExpiry` and Oban
  `:sales_maintenance` workers without weakening payment, issuance, or scanner
  boundaries.
- `ReservationLedger` remains the sole Redis inventory mutation boundary.
- VS-13 manual review queue remains the operator path for expiry hold anomalies.
