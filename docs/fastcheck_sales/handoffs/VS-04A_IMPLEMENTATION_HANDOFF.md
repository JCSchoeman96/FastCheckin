# VS-04A Implementation Handoff

## Status

Merged.

PR: #347 — docs(sales): finalize VS-04A inventory ledger contract  
Merge commit: `c1e868b78889ef0f35c3295a982484d995691e59`  
Merged at: 2026-06-16T09:38:18Z  
Branch: `cursor/vs-04a-inventory-ledger-contract-finalization`

## What Changed

VS-04A finalized the Sales inventory ledger contract as docs-only work. It made
the inventory master contract the normative authority, aligned Redis key and
operation contracts, normalized ledger error/health terminology, and documented
implementation expectations for VS-04B and VS-04C.

No runtime code, migrations, tests, config, routes, controllers, workers, or
feature-pack source docs were changed.

## Files Changed

- `docs/fastcheck_sales/inventory/INVENTORY_MASTER_CONTRACT.md` — authoritative
  precedence contract for inventory behavior, canonical key/operation/error and
  `ledger_state` terminology.
- `docs/fastcheck_sales/inventory/REDIS_KEY_STRUCTURE.md` — required key
  families, inventory hash fields, dedupe key, and non-PII key/event rules.
- `docs/fastcheck_sales/inventory/RESERVATION_LEDGER_OPERATION_CONTRACT.md` —
  `ReservationLedger` operation signatures, result envelope, health semantics,
  and required error families.
- `docs/fastcheck_sales/inventory/INVENTORY_IDEMPOTENCY_AND_LOCKING.md` —
  idempotency key shape expectations, lock constraints, dedupe retention
  guidance.
- `docs/fastcheck_sales/inventory/HOLD_TTL_AND_EXPIRY_POLICY.md` — hold TTL
  bounds, extension audit requirements, and expiry safety guarantees.
- `docs/fastcheck_sales/inventory/REDIS_FAILURE_AND_RECOVERY_POLICY.md` —
  fail-closed restart/recovery rules and reconciliation-required gating.
- `docs/fastcheck_sales/inventory/REDIS_POSTGRES_RECONCILIATION_POLICY.md` —
  durable-state precedence and reconciliation repair/report expectations.
- `docs/fastcheck_sales/inventory/INVENTORY_CACHE_AND_PUBSUB_POLICY.md` —
  topic/event naming conventions and payload constraints.
- `docs/fastcheck_sales/inventory/INVENTORY_TEST_PLAN.md` — VS-04B/VS-04C
  RED/GREEN implementation expectations.
- `docs/fastcheck_sales/slices/VS-04A_INVENTORY_LEDGER_CONTRACT_FINALIZATION.md`
  — slice summary, preserved boundaries, and follow-up sequencing note.
- `.cursor/plans/vs-04a-inventory-ledger-contract-finalization.plan.md` —
  canonical in-repo execution plan created by the slice PR.

## Contracts Now Available

- Inventory contract precedence is explicit: `INVENTORY_MASTER_CONTRACT.md`
  governs conflicts across inventory docs.
- Canonical Redis key families and `sales:offer:{offer_id}:inventory` hash field
  contract are documented.
- Canonical `ReservationLedger` API surface is documented (`reserve`, `consume`,
  `release`, `expire_due_holds`, `get_availability`, `reconcile_offer`,
  health-marking operations).
- Canonical result and error families include `:ledger_unavailable`,
  `:ledger_degraded`, and `:reconciliation_required`.
- Canonical `ledger_state` values are documented: `healthy`, `degraded`,
  `reconciliation_required`, `closed` (with optional transient `rebuilding`
  constraints).
- Fail-closed behavior under degraded/unknown/reconciliation-required states is
  explicit for all channels.
- VS-04B and VS-04C implementation-test expectations are now explicit.

## Decisions Applied

- `event_scoped_first`
- `organization_id` deferred
- Redis owns hot operational inventory/holds.
- Postgres/Ash owns durable sales intent and reconciliation truth.
- `ReservationLedger` remains the only allowed inventory mutation boundary.
- no runtime implementation in VS-04A (docs-only contract finalization).

## Boundaries Still Enforced

- No Redis Lua/runtime implementation.
- No checkout workflow implementation.
- No Paystack runtime integration.
- No Meta/WhatsApp runtime integration.
- No ticket issuance runtime.
- No attendee/scanner/mobile runtime changes.
- No admin/customer UI, routes, controllers, or worker additions.
- No Ash resource or migration changes.

## Tests Added Or Updated

No test files were changed in PR #347.

The contract is protected by rerunning existing Sales test suites during
verification.

## Verification Reported

From PR #347 body and follow-up verification:

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test test/fastcheck/sales/ticket_offer_boundary_test.exs`
- `mix test test/fastcheck/sales/ticket_offer_test.exs`
- `mix test test/fastcheck/sales/ticket_offer_policy_test.exs`
- `mix test test/fastcheck/sales/ticket_offer_cache_invalidation_test.exs`
- `mix test test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs`
- `mix test test/fastcheck/sales/`
- `mix test`
- `mix precommit`

Reported result: commands passed; CI green on PR #347 before merge.

## Known Limitations

VS-04A is contract-only. Redis inventory runtime behavior is not implemented in
code yet. There is still no `ReservationLedger` runtime module, no Lua scripts,
and no runtime checkout/payment/ticket side effects in this slice.

## Next Agent Guidance

Reuse and extend the finalized docs contract directly; do not recreate parallel
contract files.

- Treat `docs/fastcheck_sales/inventory/INVENTORY_MASTER_CONTRACT.md` as
  authoritative.
- Reuse key and error/state terminology exactly as finalized.
- Do not bypass `ReservationLedger` in any new implementation path.
- Keep durable authority in existing Sales tables/resources; do not move scanner
  or mobile hot paths into Sales inventory work.
- Keep VS-03 and VS-01G boundary/index tests green when implementation starts.

Avoid:

- introducing alternate Redis key names without contract update
- using both `inventory_unavailable` and `:ledger_unavailable` in parallel
- exposing transient `rebuilding` as an external replacement for
  `reconciliation_required`

## Next Slice

Recommended next slice:  
VS-04B — Atomic Inventory Ledger Implementation

Entry condition:

- VS-04A merged on `main`.
- Inventory contract docs are treated as implementation source of truth.
- Implementation remains within approved runtime scope (no unrelated scanner,
  attendee, or mobile API contract changes).
