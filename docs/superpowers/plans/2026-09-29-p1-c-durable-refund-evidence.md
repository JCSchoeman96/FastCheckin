# P1-C Durable Refund Evidence Implementation Plan

> **For agentic workers:** The current user instruction authorizes inline execution of this plan. Keep the work in the existing P1-C worktree and preserve the accepted base SHA.

**Goal:** Record full Paystack refund evidence durably, revoke issued tickets, finalize refund authority atomically, release only unconsumed held inventory, and keep ambiguous or consumed inventory unavailable.

**Architecture:** `FastCheck.Sales.Refund` owns provider evidence and an explicit lifecycle. Admin orchestration records evidence, uses the existing `AdminRevocations` boundary, then finalizes the PaymentAttempt, Order, Refund, and Oban handoff under the existing Order advisory lock. A separate worker reloads all commercial authority and either releases an exact held reservation or completes with consumed inventory retained. Reconciliation treats durable refund inventory resolution as authority and never infers stock restoration from `Order.status` alone.

**Tech Stack:** Phoenix 1.8, Ash resources, Ecto/PostgreSQL, Oban, Redis reservation ledger, LiveView, ExUnit.

---

## File map

- Create `priv/repo/migrations/<timestamp>_create_sales_refunds.exs` for one durable full-refund record per Order and PaymentAttempt, exact provider evidence, lifecycle state, inventory disposition, operator, and audit reason.
- Create `lib/fastcheck/sales/refund.ex` as the Sales Ash resource with evidence creation and named lifecycle transitions only; register it in `lib/fastcheck/sales.ex`.
- Modify `lib/fastcheck/sales/payment_attempt.ex` to add the named `mark_payment_refunded` action requiring the matching Refund and preserving all verification evidence.
- Modify `lib/fastcheck/sales/order.ex` so refund finalization requires a matching, accepted Refund and cannot be reached through an unqualified action or review target.
- Modify `lib/fastcheck/sales/admin_refunds.ex` to record and validate provider evidence, reuse the current revocation API and Order advisory lock, and atomically enqueue `RefundInventoryWorker` with financial state transitions.
- Create `lib/fastcheck/sales/refund_inventory.ex` for Postgres authority reload, exact hold verification, safe release/retention decisions, and retry/manual-review results.
- Create `lib/fastcheck/workers/refund_inventory_worker.ex` with only `refund_id` in job arguments and retry exhaustion handling.
- Modify `lib/fastcheck/sales/inventory/durable_snapshot.ex` and `lib/fastcheck/sales/inventory/reconciler.ex` so only completed `released_unconsumed` refunds leave sold quantity; all other refunded cases stay unavailable and ambiguous cases require manual review.
- Modify `lib/fastcheck_web/live/sales/order_show_live.ex` and its tests to collect manual Paystack Dashboard evidence and describe full refunds accurately.
- Add focused resource, orchestration, worker, reconciliation, and concurrency tests under `test/fastcheck/sales/`, `test/fastcheck/sales/inventory/`, and `test/fastcheck_web/live/sales/`; extend `test/support/admin_refund_fixtures.ex` only with reusable evidence fixtures.
- Update `docs/fastcheck_sales/feature_packs/0056_P1-C_durable-refund-evidence/`, `docs/fastcheck_sales/state_machines/ORDER_STATE_MACHINE.md`, `docs/fastcheck_sales/state_machines/PAYMENT_ATTEMPT_STATE_MACHINE.md`, `docs/fastcheck_sales/state_machines/STATE_MACHINE_MASTER.md`, and `docs/fastcheck_sales/inventory/REDIS_POSTGRES_RECONCILIATION_POLICY.md`.

## Task 1: Add durable Refund evidence

Files: migration, `refund.ex`, `sales.ex`, `test/fastcheck/sales/admin_refunds_test.exs`.

- Add a one-per-Order and one-per-PaymentAttempt refund record with provider fixed to `paystack`, `provider_status`, provider RRN/reference, provider refund timestamp, exact amount/currency, admin identity, reason, lifecycle status, and nullable inventory resolution.
- Constrain lifecycle values to `evidence_recorded`, `revocation_complete`, `inventory_pending`, `revocation_manual_review`, `inventory_manual_review`, and `completed`; constrain inventory resolution to `released_unconsumed` or `retained_consumed`.
- Add only named transitions for revocation success/failure, audited retry from the two manual-review states, inventory pending/manual/completed, and no generic status mutation.
- Test provider/status/reference/timestamp/operator/reason requirements, full amount and currency matching, duplicate-identical idempotency, conflicting evidence rejection, and legal lifecycle transitions.
- Run `mix test test/fastcheck/sales/admin_refunds_test.exs`; require all new cases to pass.

## Task 2: Tie refund finalization to payment and order authority

Files: `payment_attempt.ex`, `order.ex`, `admin_refunds.ex`, `test/fastcheck/sales/admin_refunds_test.exs`.

- Add `PaymentAttempt.mark_payment_refunded(refund_id)` with exactly `verified_success → refunded`, matching Order and Refund, and exact amount/currency checks. A repeated matching transition is idempotent; other states reject. Do not accept or clear provider verification fields.
- Replace the naked Order refund action with a named action that requires `refund_id` and verifies Refund ownership, selected PaymentAttempt, accepted evidence, exact money, revocation completion, and zero issued TicketIssues. Remove or close any other Ash transition that can target `refunded` without these proofs.
- Select exactly one verified-success PaymentAttempt matching the Order. Zero or multiple candidates fail closed; never choose the latest of several plausible attempts.
- Require an admin actor, event scope, nonblank reason, valid existing admin password, provider `paystack`, status `processed`, provider reference/RRN, timestamp, full amount/currency, and reject partial refunds.
- Persist evidence before ticket revocation. If revocation fails, retain the evidence and move Refund to `revocation_manual_review`; do not transition the Order or PaymentAttempt.
- After revocation, begin one Postgres transaction, acquire the existing `pg_advisory_xact_lock(order_id)`, reload and recheck all authority plus zero issued TicketIssues, transition PaymentAttempt and Order, transition Refund to `inventory_pending`, and insert the unique inventory worker. Redis must not be called in this transaction; queue insertion failure must roll back all financial transitions.
- Test the exact provider/evidence validation matrix, ambiguous PaymentAttempt selection, revocation evidence retention and no-finalization, zero-issued guard, PaymentAttempt idempotency/preservation, and rejection of direct naked `Order.refunded` updates.
- Run `mix test test/fastcheck/sales/admin_refunds_test.exs`.

## Task 3: Resolve held and consumed inventory conservatively

Files: `refund_inventory.ex`, `refund_inventory_worker.ex`, `reservation_ledger.ex` only if a narrow exact dedupe-result read is required, focused refund inventory tests, and paid-fulfillment boundary tests.

- Worker args contain only `refund_id`; reload Refund, Order, the single authoritative OrderLine, and all expected identifiers from Postgres.
- Verify hold offer, Order public reference, and quantity exactly. For `held`, call `ReservationLedger.release/3` with `refund:release:<refund_id>` and accept completion only when the exact release operation succeeds or its matching idempotency result proves this Refund performed it.
- For exact `consumed`, perform no Redis mutation and no counter adjustment; set `retained_consumed` and complete the Refund.
- For missing, expired, malformed, mismatched, wrong-offer, wrong-quantity, or unverifiable state, set `inventory_manual_review`; never infer availability.
- Retry Redis unavailable and lock timeout outcomes using Oban attempts; on final exhaustion move Refund to `inventory_manual_review`.
- Make repeat held release idempotent. Never implement a consumed restoration operation or `restored_consumed` result.
- Add the ordering race test: allow `PaidOrderFulfillment` to consume before its Order lock, let refund finalization win, then require the refund worker to complete `retained_consumed` with unchanged Redis available and consumed quantities.
- Run focused refund, reservation-ledger, and paid-fulfillment tests.

## Task 4: Make reconciliation honor refund inventory evidence

Files: `durable_snapshot.ex`, `reconciler.ex`, `test/fastcheck/sales/inventory/reconciler_test.exs`, `test/fastcheck/sales/inventory/reconciliation_boundary_test.exs`.

- Count a refunded Order as sold unless it has exactly one matching completed Refund with `released_unconsumed` resolution.
- Keep `retained_consumed`, `inventory_pending`, `inventory_manual_review`, and legacy refunded Orders with no Refund counted as sold/unavailable.
- Report `legacy_refund_without_provider_evidence`, `refund_inventory_resolution_pending`, and `refund_inventory_resolution_manual_review` (or equally specific repository-consistent atoms); ambiguous evidence sets `manual_review_required?` and prevents upward repair.
- Test released capacity becoming available, retained capacity remaining sold, pending/manual review remaining unavailable, a legacy refunded Order never raising availability, and reconciliation repair behavior at the Redis boundary.
- Run focused snapshot/reconciler tests.

## Task 5: Update the admin refund flow and authoritative docs

Files: `order_show_live.ex`, `test/fastcheck_web/live/sales/order_show_live_test.exs`, P1-C feature pack `0056`, Order/PaymentAttempt/master state machines, reconciliation policy.

- Replace the old “mark refunded” marker form with evidence fields for Paystack refund reference/RRN and provider refund time, retaining reason and the current admin-password requirement. Make the form state this is a manually completed full Paystack Dashboard refund and performs no provider API call.
- Describe consumed inventory as deliberately retained, pending/manual inventory as unavailable, and legacy refunds as requiring review.
- Document: P1-C does not reclaim consumed inventory because browser, asynchronous backend-mobile, and local-first Android admissions lack one global unused-ticket proof; consumed-capacity reclaim is a future feature blocked on unified admission/usage authority.
- Remove any P1-C claim that `consumed → restored` is implemented. Do not alter scanner or Android runtime files.
- Run focused LiveView tests and inspect the full documentation diff for contradictory refund language.

## Task 6: Verify the complete slice

- Run focused tests for Refund, AdminRefunds, PaymentAttempt refund transition, refund inventory worker, reconciler, and Order Show LiveView.
- Run `mix format --check-formatted`, `mix precommit`, the repository-standard Sobelow command, and repository-standard base/head Dialyzer comparison. Fix all findings; do not add tests unrelated to the slice.
- Run `git diff --check`; inspect `git status` and `git diff` for PII logging, route/auth regressions, scanner changes, and every user STOP condition.
- Push only after local gates are clean, then confirm exact-head GitHub CI is green. Create a detailed PR; do not merge it.

## STOP checks

- Stop if `origin/main` moves from `ad83c53e05d691a4b74c4e6c37f4ee1d91fca643`, an overlapping refund implementation appears, full refund cannot select exactly one verified-success attempt, the zero-issued invariant fails, the Order can become refunded without durable Refund evidence, a consumed hold is ever changed, retained consumed quantity contributes to availability, Redis runs in the Postgres financial transaction, an unexpected scanner/Android edit is needed, or required local/Sobelow/Dialyzer/GitHub checks fail.
