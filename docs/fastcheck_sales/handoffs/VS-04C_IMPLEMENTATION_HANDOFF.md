# VS-04C Implementation Handoff

## Status

Merged.

PR: #353 — feat(sales): implement VS-04C inventory reconciliation and recovery  
Merge commit: `1a44610e5cf79bac69b401da90ddd1b27134ac8a`  
Merged at: 2026-06-16T15:21:41Z  
Branch: `vs-04c-inventory-reconciliation-recovery`

## What Changed

VS-04C added read-only inventory health checks, durable-vs-Redis reconciliation,
and safe recovery paths for FastCheck Sales offers. Postgres/Ash order and
checkout-session state is compared against the VS-04B Redis hot ledger; repair
is dry-run by default and requires explicit opt-in.

The slice extended `ReservationLedger` with offer-scoped hold reads, health
marking, inventory rebuild, and allowlist-based stale-hold expiry. An Oban worker
on the `sales_inventory` queue can run reconciliation per offer. Orphan Redis
holds (refs without matching durable `sales_orders.public_reference`) force
`manual_review_required` and block auto-rebuild.

## Files Changed

- `lib/fastcheck/sales/inventory/durable_snapshot.ex` — offer-scoped Postgres
  reads for sold/active-hold/manual-review counts, `safe_available`, order ref
  lookup, and hold-expiry classification for stale-hold allowlists.
- `lib/fastcheck/sales/inventory/health.ex` — read-only `offer_health/1` and
  `HealthReport`; compares durable snapshot to Redis without mutation.
- `lib/fastcheck/sales/inventory/reconciler.ex` — `reconcile_offer/2` dry-run
  default; drift/missing-Redis/orphan analysis; delegates repair to Recovery.
- `lib/fastcheck/sales/inventory/recovery.ex` — `rebuild_offer_inventory/2`,
  `repair_stale_holds/3`, and internal `apply_safe_repairs/4`; mutates Redis only
  through `ReservationLedger`.
- `lib/fastcheck/sales/inventory/reconciliation_worker.ex` — Oban worker on
  `:sales_inventory`; `mode: "dry_run"` default, `mode: "repair"` for mutations.
- `lib/fastcheck/sales/inventory/reservation_ledger.ex` — added
  `expire_due_holds_for_offer/3` (optional `allowed_refs:`), hold read helpers
  (`list_hold_refs/1`, `list_due_hold_refs/2`, `get_hold_detail/2`,
  `list_offer_holds/1`), `mark_offer_health/3`, `rebuild_inventory/2`.
- `config/config.exs` — Oban queue `sales_inventory: 5`.
- `test/fastcheck/sales/inventory/health_test.exs` — healthy and missing-Redis
  health reporting.
- `test/fastcheck/sales/inventory/reconciler_test.exs` — dry-run/repair drift,
  missing-hash rebuild, orphan manual-review, idempotency, PII log safety.
- `test/fastcheck/sales/inventory/recovery_test.exs` — rebuild after key loss,
  safe stale-hold expiry, paid/unknown/consumed/orphan guardrails.
- `test/fastcheck/sales/inventory/reconciliation_worker_test.exs` — dry-run
  default and Oban uniqueness.
- `test/fastcheck/sales/inventory/reconciliation_boundary_test.exs` — reconciliation
  modules must not embed Redis key strings; mutation ownership unchanged.

## Contracts Now Available

- `FastCheck.Sales.Inventory.Health.offer_health/1` — read-only health report.
- `FastCheck.Sales.Inventory.Reconciler.reconcile_offer/2` — returns
  `{:ok, %ReconciliationReport{}}`, `{:manual_review_required, report}`, or
  `{:error, reason}`; accepts missing Redis as
  `{:error, :reconciliation_required, meta}` input state.
- `FastCheck.Sales.Inventory.Recovery.rebuild_offer_inventory/2` and
  `repair_stale_holds/3` — safe rebuild and allowlisted stale-hold repair.
- `FastCheck.Sales.Inventory.ReconciliationWorker` — scheduled/manual reconcile
  entrypoint under `lib/fastcheck/sales/inventory/` (not `lib/fastcheck/workers/`).
- `FastCheck.Sales.Inventory.DurableSnapshot` — durable counts and hold-ref
  classification helpers for reconciliation.
- `ReservationLedger` extended helpers for hold inspection and bounded expiry
  with `allowed_refs:`.
- Oban queue `:sales_inventory` configured in `config/config.exs`.
- Telemetry events under `[:fastcheck, :sales, :inventory, ...]` for reconcile,
  rebuild, manual review, and health checks.
- Boundary tests guard Redis key ownership and reconciliation module scope.

## Decisions Applied

- `event_scoped_first`
- `organization_id` deferred
- Postgres/Ash durable state is authoritative over Redis for reconciliation.
- Redis mutations only through `ReservationLedger` / `RedisScripts`.
- Dry-run by default; `allow_repair: true` required for mutating repair.
- Ambiguous state (`manual_review_required`, negative `safe_available`, orphan
  holds) returns `manual_review_required` and does not auto-repair.
- Orphan Redis holds are never auto-repaired or auto-expired.
- Stale-hold expiry uses durable-proven unpaid allowlist only.
- Reconciliation worker lives under `lib/fastcheck/sales/inventory/` to satisfy
  VS-01F/VS-01G boundary rules.
- No checkout workflow changes; tests may seed holds via
  `Checkout.start_checkout/3` and `FastCheck.SalesCheckoutFixtures`.

## Boundaries Still Enforced

- No checkout, payment, Paystack, or order workflow changes.
- No Meta/WhatsApp runtime.
- No ticket issuance, attendee bridge, or delivery runtime.
- No scanner or mobile API changes.
- No admin/customer sales UI, routes, controllers, or LiveViews.
- No Ash resource direct Redis mutation.
- No automatic offer-to-inventory initialization on offer enablement.
- No inventory event-trail writes to `sales:inventory:events:{offer_id}`.
- No scheduled Oban cron wiring for reconciliation (worker exists; scheduling
  is not shipped).
- No operator/admin reconciliation UI or exports.
- Reconciliation does not call `Checkout.start_checkout/3` at runtime.

## Tests Added Or Updated

- `test/fastcheck/sales/inventory/health_test.exs` — healthy Redis and missing
  inventory hash reporting.
- `test/fastcheck/sales/inventory/reconciler_test.exs` — missing-hash dry-run and
  repair, orphan `manual_review_required`, drift dry-run/repair, negative
  `safe_available`, idempotent duplicate runs, log redaction.
- `test/fastcheck/sales/inventory/recovery_test.exs` — Redis rebuild after key
  loss, durable-proven unpaid hold expiry, paid/unknown/consumed hold guards,
  orphan rebuild refusal, negative safe-available refusal.
- `test/fastcheck/sales/inventory/reconciliation_worker_test.exs` — worker
  dry-run default and uniqueness dedup.
- `test/fastcheck/sales/inventory/reconciliation_boundary_test.exs` — no Redis
  key strings in reconciliation modules; mutation allowlist unchanged.

## Verification Reported

From final implementation on merge commit `1a44610e5cf79bac69b401da90ddd1b27134ac8a`:

- `mix format --check-formatted` — passed
- `mix compile --warnings-as-errors` — passed
- `mix test test/fastcheck/sales/inventory/recovery_test.exs` — 7 tests, 0 failures
- `mix test test/fastcheck/sales/inventory/` — 37 tests, 0 failures
- `mix test test/fastcheck/sales/` — 172 tests, 0 failures
- `mix precommit` — 513 tests, 0 failures, 4 skipped

## Known Limitations

- `ReconciliationWorker` is implemented but not cron-scheduled; enqueue manually
  or add scheduling in a later ops slice.
- `expire_due_holds/1` global scan behavior is unchanged from VS-04B; safe
  allowlisted expiry is used by `Recovery.repair_stale_holds/3` only.
- Orphan holds require manual review; no automated orphan cleanup.
- No reconciliation operator UI, dashboards, or CSV exports.
- `initialize_offer/2` is still not wired to offer lifecycle automation.
- Inventory audit/event trail keys remain documented but not written at runtime.
- Upward Redis availability repair is conservative; ambiguous upward drift with
  manual-review orders stays `manual_review_required`.

## Next Agent Guidance

Reuse directly:

- `FastCheck.Sales.Inventory.Reconciler`, `Recovery`, `Health`, and
  `DurableSnapshot` for inventory reconciliation work.
- `FastCheck.Sales.Inventory.ReconciliationWorker` for background reconcile jobs.
- `FastCheck.Sales.Inventory.ReservationLedger` for all Redis inventory mutations
  and hold reads.
- `FastCheck.Sales.Checkout.start_checkout/3` and
  `test/support/sales_checkout_fixtures.ex` to seed realistic hold state in tests.
- VS-04A inventory contract docs for error families and key naming.

Do not:

- mutate inventory Redis keys outside `ReservationLedger` / `RedisScripts`
- bypass `manual_review_required` for orphan holds or negative `safe_available`
- auto-expire paid, manual-review, refunded, missing-order, or orphan holds
- place Sales workers under `lib/fastcheck/workers/` (VS-01F/VS-01G boundary)
- add reconciliation to the checkout request hot path
- log PII, tokens, or provider payloads in reconciliation telemetry

Keep green when extending Sales:

- all `test/fastcheck/sales/inventory/**` files (including reconciliation tests)
- `test/fastcheck/sales/checkout_*` and `order_checkout_core_test.exs`
- full `mix test test/fastcheck/sales/`

## Next Slice

Recommended next slice:  
VS-05A — Secondary Sales Entry Points

Entry condition:

- VS-05 merged on `main` with `Checkout.start_checkout/3` as the checkout
  authority.
- VS-04B `ReservationLedger` remains the inventory mutation boundary.
- VS-04C reconciliation/recovery modules are available for post-checkout drift
  and Redis-loss recovery when needed.

Also unblocked for parallel payment work: VS-06A — Paystack Client Boundary.
