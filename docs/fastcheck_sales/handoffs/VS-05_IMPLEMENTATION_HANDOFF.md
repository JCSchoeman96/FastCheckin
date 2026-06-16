# VS-05 Implementation Handoff

## Status

Merged.

PR: #351 — feat(sales): implement VS-05 order and checkout core  
Merge commit: `1f08441b0eebcf5ad153cf99c4403f5a34fa3f94`  
Merged at: 2026-06-16T14:03:21Z  
Branch: `vs-05-order-and-checkout-core`

## What Changed

VS-05 implemented the core Sales checkout orchestration boundary. It added
`FastCheck.Sales.Checkout.start_checkout/3` as the single entrypoint for channel
adapters, named Ash workflow actions on `Order`, `OrderLine`, `CheckoutSession`,
and `StateTransition`, and durable audit logging via
`FastCheck.Sales.StateTransitionSupport`.

Checkout now creates draft orders, immutable order-line price snapshots,
checkout sessions, and Redis inventory holds through
`ReservationLedger.reserve/5`. It reaches `awaiting_payment` only after a hold
is attached, compensates with `ReservationLedger.release/3` on post-reserve
failures, and moves to `manual_review` when release fails.

Post-merge review fixes in the same squash merge hardened idempotency matching
(full checkout identity comparison before replay), required authorization before
returning existing checkout data, and moved hold-token pepper configuration to
`SALES_HOLD_TOKEN_PEPPER` in `config/runtime.exs`.

## Files Changed

- `lib/fastcheck/sales/checkout.ex` — approved checkout orchestration boundary;
  idempotency lookup, offer validation, hold-token hashing, compensation.
- `lib/fastcheck/sales/state_transition_support.ex` — shared helper to append
  `StateTransition` rows with sanitized metadata.
- `lib/fastcheck/sales/order.ex` — named workflow actions (`create_draft`,
  `confirm_checkout`, `mark_awaiting_payment`, lifecycle updates,
  `get_by_idempotency_key`) and transition hooks.
- `lib/fastcheck/sales/order_line.ex` — `create_for_order`, `list_for_order`;
  immutable checkout snapshots.
- `lib/fastcheck/sales/checkout_session.ex` — session workflow actions including
  `create_session`, `attach_inventory_hold`, expiry/release/manual-review paths.
- `lib/fastcheck/sales/state_transition.ex` — `record_transition`,
  `list_for_entity`; manual-transition reason validation.
- `lib/fastcheck/sales/inventory/reservation_ledger.ex` — public `hold_key/1`
  helper for checkout hold key construction.
- `priv/repo/migrations/20260616140000_add_internal_pilot_source_channel.exs` —
  adds `internal_pilot` to `sales_orders_source_channel_valid`.
- `config/config.exs` — `:sales_checkout_hold_ttl_seconds` (600).
- `config/runtime.exs` — `SALES_HOLD_TOKEN_PEPPER` with prod required/length
  checks and dev fallback; skipped in `:test`.
- `config/test.exs` — test-only `:sales_hold_token_pepper`.
- `docs/fastcheck_sales/slices/VS-05_ORDER_AND_CHECKOUT_CORE.md` — slice
  implementation summary.
- `test/support/sales_checkout_fixtures.ex` — shared checkout test fixtures.
- `test/fastcheck/sales/order_checkout_core_test.exs` — happy path, offer/channel
  validation, inventory fail-closed, compensation, log redaction.
- `test/fastcheck/sales/checkout_idempotency_test.exs` — replay safety and
  conflict cases for offer, quantity, channel, and event.
- `test/fastcheck/sales/checkout_policy_test.exs` — actor authorization and
  forbidden replay behavior.
- `test/fastcheck/sales/checkout_session_test.exs` — hold attachment, hashed
  hold token, pepper config assertion.
- `test/fastcheck/sales/checkout_inventory_boundary_test.exs` — checkout does not
  own inventory Redis key strings.
- `test/fastcheck/sales/order_line_snapshot_test.exs` — immutable line pricing.
- `test/fastcheck/sales/order_state_transition_test.exs` — appended transitions
  and manual admin reason requirement.
- Legacy skeleton/boundary tests under `test/fastcheck/sales/` — updated for VS-05
  workflow actions and resource attributes.

## Contracts Now Available

- `FastCheck.Sales.Checkout.start_checkout/3` is the only approved checkout
  orchestration entrypoint.
- Checkout actors: `system`, `admin`, and event-scoped `customer_session`.
  Operators are forbidden.
- Idempotency flow:
  1. validate quantity
  2. internal lookup by `idempotency_key`
  3. return `:duplicate_idempotency_conflict` on input mismatch
  4. authorize actor/event
  5. replay sanitized existing checkout or create a new one
- Idempotent replay requires matching `event_id`, `source_channel`,
  `ticket_offer_id`, `quantity`, `event_name_snapshot`, buyer fields, and
  `effective_sales_channel` (stored on order-line `metadata`).
- Offer validation uses system `TicketOffer.get_by_id` with explicit error atoms
  (`:offer_not_found`, `:sales_disabled`, `:sales_window_closed`,
  `:sales_channel_unavailable`, etc.).
- `system`/`test` source channels require explicit `effective_sales_channel` in
  opts.
- Hold tokens are peppered SHA-256 hashes of opaque bytes; raw idempotency keys
  are never stored as `hold_token`.
- Returned checkout sessions are sanitized (`hold_token` removed).
- `ReservationLedger.hold_key/1` is public for hold key construction.
- `sales_orders` accepts `internal_pilot` as a `source_channel`.
- State transitions append through `StateTransitionSupport.record!/2` with
  metadata sanitization for buyer fields and token/idempotency values.

## Decisions Applied

- `event_scoped_first`
- `organization_id` deferred
- integer cents for money fields
- named Ash actions only; no generic `update_status` / `update_state`
- Redis hot inventory via `ReservationLedger`; Postgres/Ash durable sales truth
- single checkout orchestration module; no direct Redis calls in `Checkout`
- hold token hashing with runtime pepper secret
- deterministic compensation: no `awaiting_payment` until hold attached
- manual admin/operator transitions require `reason` on cancelled/manual_review
  sources only

## Boundaries Still Enforced

- No Paystack client, initialization, webhooks, or payment verification.
- No Meta/WhatsApp runtime, conversations, or outbound messaging.
- No ticket issuance, attendee bridge, or delivery runtime.
- No scanner, mobile API, router, controller, LiveView, or worker changes.
- No admin/customer sales UI.
- No `PaymentAttempt` / `PaymentEvent` workflow actions beyond existing skeletons.
- No inventory reconciliation/recovery (`reconcile_offer/1`, degraded/healthy
  markers) — still VS-04C scope.
- No checkout expiry/cleanup workers — still later slices.
- No channel-specific adapters (WhatsApp/web/admin entrypoints) — still VS-05A
  and later slices.

## Tests Added Or Updated

- `test/fastcheck/sales/order_checkout_core_test.exs` — full checkout flow,
  channel/offer errors, inventory unavailable, insufficient inventory,
  compensation, PII/token log checks.
- `test/fastcheck/sales/checkout_idempotency_test.exs` — stable replay,
  conflict on event/offer/quantity/effective channel mismatch.
- `test/fastcheck/sales/checkout_policy_test.exs` — system/admin allowed,
  operator forbidden, customer_session scoped access, forbidden replay.
- `test/fastcheck/sales/checkout_session_test.exs` — hold attach, hashed token,
  pepper configured in test.
- `test/fastcheck/sales/checkout_inventory_boundary_test.exs` — inventory Redis
  ownership boundary from checkout slice perspective.
- `test/fastcheck/sales/order_line_snapshot_test.exs` — immutable snapshots
  after offer price change.
- `test/fastcheck/sales/order_state_transition_test.exs` — transition append and
  manual cancel reason enforcement.
- `test/support/sales_checkout_fixtures.ex` — offer/order/checkout test helpers.
- Updated skeleton/boundary tests: `core_resource_skeletons_test.exs`,
  `checkout_and_payment_resource_skeletons_test.exs`, `domain_shell_test.exs`,
  `vs_01c_boundary_test.exs`, `vs_01f_boundary_test.exs`,
  `vs_01g_index_and_migration_verification_test.exs`.

## Verification Reported

From PR #351 and final implementation on merge commit `1f08441b`:

- `mix format --check-formatted` — passed
- `mix compile --warnings-as-errors` — passed
- VS-05 targeted tests (7 files) — passed
- `mix test test/fastcheck/sales/` — 151 tests, 0 failures
- `mix test` — 492 tests, 0 failures, 4 skipped
- `mix precommit` — passed (format, compile, credo, full test suite)

CI was green on PR #351 before squash merge to `main`.

## Known Limitations

- Checkout stops at `awaiting_payment` with `hold_attached` session; no payment
  link generation, Paystack init, or webhook handling.
- `mark_payment_link_sent`, payment-pending, and paid-state transitions exist as
  Ash actions but are not wired to provider runtime.
- No Oban/worker-driven checkout expiry or hold cleanup.
- No automatic offer-to-inventory initialization on offer enablement.
- `ReservationLedger.reconcile_offer/1` and degraded/healthy recovery remain
  unimplemented (VS-04C).
- Channel adapters must call `Checkout.start_checkout/3`; none are shipped in
  this slice.
- `customer_session` may start checkout only for allowed events; broader order
  reads remain policy-restricted.

## Next Agent Guidance

Reuse directly:

- `FastCheck.Sales.Checkout.start_checkout/3` for all new channel entrypoints.
- Named Ash actions on `Order`, `OrderLine`, `CheckoutSession`, and
  `StateTransition`; do not add generic status updates.
- `FastCheck.Sales.StateTransitionSupport` for append-only audit logging.
- `FastCheck.Sales.Inventory.ReservationLedger` for reserve/release/consume;
  never mutate inventory Redis keys elsewhere.
- `test/support/sales_checkout_fixtures.ex` and the seven VS-05 checkout test
  files as regression guards.
- `docs/fastcheck_sales/slices/VS-05_ORDER_AND_CHECKOUT_CORE.md` for slice-local
  behavior summary.
- VS-04A inventory contract docs for inventory error families and key naming.

Do not:

- bypass `Checkout.start_checkout/3` with ad-hoc order/session creation from
  channel code
- store raw idempotency keys or opaque hold bytes as `hold_token`
- return idempotent replay before actor authorization
- weaken idempotency matching to only `event_id` + `source_channel`
- add Paystack/WhatsApp/ticket/scanner/mobile changes inside checkout slices
- hard-code `sales_hold_token_pepper` in `config/config.exs`

Keep green when extending Sales:

- all seven `test/fastcheck/sales/checkout_*` and `order_checkout_core_test.exs`
  files
- `test/fastcheck/sales/order_line_snapshot_test.exs`
- `test/fastcheck/sales/order_state_transition_test.exs`
- `test/fastcheck/sales/inventory/**`
- full `mix test test/fastcheck/sales/`

Production config note: set `SALES_HOLD_TOKEN_PEPPER` (minimum 32 bytes) before
booting releases.

## Next Slice

Recommended next slice:  
VS-04C — Inventory Reconciliation and Recovery

Entry condition:

- VS-05 merged on `main` with checkout/order/session states and transitions
  available for reconciliation against Redis holds.
- VS-04B `ReservationLedger` hot path remains the inventory mutation authority.
- VS-04A inventory contract docs remain authoritative.

Also now unblocked by VS-05: VS-05A — Secondary Sales Entry Points.
