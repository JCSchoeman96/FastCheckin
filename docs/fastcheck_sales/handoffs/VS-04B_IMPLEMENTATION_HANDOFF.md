# VS-04B Implementation Handoff

## Status

Merged.

PR: #349 — feat(sales): implement VS-04B atomic inventory ledger boundary  
Merge commit: `83d1066cfd3beb801bc093322c975bdb2c33ed78`  
Merged at: 2026-06-16T10:59:27Z  
Branch: `vs-04b-atomic-inventory-ledger`

## What Changed

VS-04B implemented the Redis/Lua-backed Sales inventory hot path. It added
`FastCheck.Sales.Inventory.ReservationLedger` as the public mutation boundary and
`FastCheck.Sales.Inventory.RedisScripts` as the only Lua execution surface for
atomic reserve, consume, release, expiry, and availability reads.

The slice enforces fail-closed behavior when Redis is unavailable, avoids
Repo/Ash/TicketOffer reads on the hot path, uses direct `Redix.command/2`
against `FastCheck.Redix` (not the ETS fallback wrapper), and adds focused
inventory tests plus minimal legacy Sales boundary-test updates.

Review follow-ups in the same squash merge normalized public errors to the VS-04A
contract, fixed `release/3` result envelopes, added per-order Redis locks, and
prevented double-reserve for the same `order_public_reference` with a different
idempotency key.

## Files Changed

- `lib/fastcheck/sales/inventory/reservation_ledger.ex` — public inventory API:
  `initialize_offer/2`, `reserve/5`, `consume/4`, `release/3`, `expire_due_holds/1`,
  `get_availability/1`; key helpers; fail-closed Redis command wrapper.
- `lib/fastcheck/sales/inventory/redis_scripts.ex` — Lua scripts for reserve,
  consume, release, and single-hold expiry; canonical error decoding; order-lock
  acquisition (`SET NX PX`); dedupe handling.
- `test/fastcheck/sales/inventory/reservation_ledger_test.exs` — RED/GREEN
  behavior for reserve/consume/release/expiry, canonical errors, idempotency,
  order-reference safety, lock timeout, and Redis cleanup.
- `test/fastcheck/sales/inventory/reservation_ledger_concurrency_test.exs` — 25
  parallel reserves against 10 units never oversell.
- `test/fastcheck/sales/inventory/redis_scripts_test.exs` — script entrypoints,
  Redis-unavailable normalization, and canonical Lua status decoding.
- `test/fastcheck/sales/inventory/inventory_boundary_test.exs` — only
  `ReservationLedger` and `RedisScripts` may own Sales inventory Redis mutation
  key strings.
- `test/fastcheck/sales/core_resource_boundary_test.exs` — removed stale
  assertion that `lib/fastcheck/sales/inventory` must be absent.
- `test/fastcheck/sales/ticket_offer_boundary_test.exs` — same stale-absence
  cleanup.
- `test/fastcheck/sales/vs_01c_boundary_test.exs` — same stale-absence cleanup.
- `test/fastcheck/sales/vs_01d_boundary_test.exs` — same stale-absence cleanup.
- `test/fastcheck/sales/vs_01e_boundary_test.exs` — same stale-absence cleanup.
- `test/fastcheck/sales/vs_01f_boundary_test.exs` — same stale-absence cleanup.
- `test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs` — same
  stale-absence cleanup.
- `.cursor/plans/vs-04b-atomic-inventory-ledger.plan.md` — canonical in-repo
  execution plan artifact from the slice PR.

## Contracts Now Available

- `FastCheck.Sales.Inventory.ReservationLedger` exists and is the only allowed
  Sales inventory mutation boundary.
- `FastCheck.Sales.Inventory.RedisScripts` is the only module that executes
  inventory Lua scripts.
- Hot-path operations implemented:
  - `initialize_offer/2`
  - `reserve/5`
  - `consume/4`
  - `release/3`
  - `expire_due_holds/1`
  - `get_availability/1`
- Redis key families in use:
  - `sales:offer:{offer_id}:inventory`
  - `sales:offer:{offer_id}:holds`
  - `sales:hold:{public_reference}`
  - `sales:order:{public_reference}:lock`
  - `sales:inventory:dedupe:{operation}:{idempotency_key}`
- Result envelope is `{:ok, map()}` or `{:error, atom(), metadata_map}`.
- Public error families now used in code include `:ledger_unavailable`,
  `:reconciliation_required`, `:insufficient_inventory`, `:invalid_idempotency_key`,
  `:invalid_quantity`, `:hold_not_found`, `:hold_expired`, `:already_consumed`,
  `:already_released`, and `:lock_timeout`.
- Redis unavailable fails closed as `{:error, :ledger_unavailable, metadata}`.
- Missing/uninitialized Redis inventory hash fails as
  `{:error, :reconciliation_required, metadata}`; there is no public
  `:offer_not_initialized` error.
- Reserve is idempotent by idempotency key and also safe by
  `order_public_reference` (same held order with different idempotency key does
  not double-mutate counters).
- Inventory boundary test guards against direct Redis mutation outside the two
  inventory modules.

## Decisions Applied

- `event_scoped_first`
- `organization_id` deferred
- Redis owns hot operational inventory and holds; Postgres/Ash remains durable
  sales truth for later reconciliation slices.
- `ReservationLedger` is the only inventory mutation boundary.
- No Redis ETS fallback on the inventory hot path.
- VS-04A inventory contract docs are the error/key/operation authority.
- Canonical VS-04A error families only in the public API; richer detail lives in
  metadata (for example `reason: :duplicate_conflict`, `field: :ttl_seconds`).
- Per-order lock key `sales:order:{public_reference}:lock` with bounded TTL and
  `:lock_timeout` on contention.

## Boundaries Still Enforced

- No checkout workflow or order state machine implementation.
- No Paystack/payment runtime.
- No Meta/WhatsApp runtime.
- No ticket issuance runtime.
- No attendee/scanner/mobile API changes.
- No admin/customer UI, routes, controllers, LiveViews, or workers.
- No full Redis/Postgres reconciliation tooling (`reconcile_offer/1`,
  `mark_offer_degraded/2`, `mark_offer_healthy/1` are not implemented).
- No inventory event-trail writes to `sales:inventory:events:{offer_id}`.
- No automatic wiring from `TicketOffer` lifecycle to `initialize_offer/2`.
- No Ash resource direct Redis mutation.

## Tests Added Or Updated

- `test/fastcheck/sales/inventory/reservation_ledger_test.exs` — reserve/consume
  idempotency, reconciliation-required on missing hash, duplicate idempotency
  conflict, invalid TTL, release idempotent replay vs terminal conflicts,
  expired-hold release, lock timeout, order-reference dedupe safety, and expiry
  behavior.
- `test/fastcheck/sales/inventory/reservation_ledger_concurrency_test.exs` — 25
  parallel reserves produce exactly 10 successes and 15 insufficient-inventory
  failures.
- `test/fastcheck/sales/inventory/redis_scripts_test.exs` — script exports,
  ledger-unavailable normalization, unexpected Lua response handling, and
  canonical error decoding.
- `test/fastcheck/sales/inventory/inventory_boundary_test.exs` — inventory Redis
  mutation ownership allowlist.
- Legacy Sales boundary tests listed above — removed only the stale assertion
  that `lib/fastcheck/sales/inventory` must not exist.

## Verification Reported

From PR #349 implementation and final review on commit `477be2180780468106c3afcaa03f82c3f46074cc`:

- `mix format --check-formatted` — passed
- `mix compile --warnings-as-errors` — passed
- `mix test test/fastcheck/sales/inventory/` — 16 tests, 0 failures
- `mix test test/fastcheck/sales/` — 121 tests, 0 failures
- `mix precommit` — 462 tests, 0 failures, 4 skipped

CI was green on the final PR head before squash merge to `main`.

## Known Limitations

- Reconciliation/recovery operations documented in VS-04A remain unimplemented;
  they belong to VS-04C.
- `initialize_offer/2` exists but is not yet integrated with offer enablement or
  durable offer lifecycle automation.
- `expire_due_holds/1` discovers offer IDs by scanning hold zset keys; there is
  no Oban/worker scheduling in this slice.
- Inventory audit/event trail keys are documented but not written at runtime.
- Checkout, payment, and channel adapters must call `ReservationLedger`; that
  orchestration is not part of VS-04B.

## Next Agent Guidance

Reuse directly:

- `FastCheck.Sales.Inventory.ReservationLedger` for all live reserve/consume/
  release/expiry/availability behavior.
- `docs/fastcheck_sales/inventory/INVENTORY_MASTER_CONTRACT.md` and the other
  VS-04A inventory docs for terminology and error families.
- `test/fastcheck/sales/inventory/**` as the regression suite for inventory
  behavior and ownership boundaries.

Do not:

- mutate inventory Redis keys outside `ReservationLedger` / `RedisScripts`
- route inventory hot paths through `FastCheck.Redis` ETS fallback
- expose non-canonical public error atoms bypassing VS-04A families
- reintroduce `{:ok, atom()}` terminal outcomes on `release/3`
- allow a second reserve for the same `order_public_reference` to decrement
  counters again

Keep green when extending Sales:

- `test/fastcheck/sales/inventory/**`
- `test/fastcheck/sales/ticket_offer_boundary_test.exs`
- `test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs`
- full `mix test test/fastcheck/sales/`

## Next Slice

Recommended next slice:  
VS-05 — Order and Checkout Core

Entry condition:

- VS-04B merged on `main` with `ReservationLedger` available for checkout holds.
- VS-04A inventory contract docs remain authoritative.
- VS-01C checkout/payment skeletons and VS-03 ticket offer management are already
  merged and available.
- VS-04C remains blocked until VS-05 is merged (`implementation_blocked_until_VS-05`
  in the VS-04C feature pack).
