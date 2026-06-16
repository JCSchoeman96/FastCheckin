# VS-05 Order and Checkout Core

## Status

Implemented checkout orchestration for FastCheck Sales.

## Scope

VS-05 adds named Ash workflow actions on `Order`, `OrderLine`, `CheckoutSession`,
and `StateTransition`, plus a single orchestration boundary at
`FastCheck.Sales.Checkout.start_checkout/3`.

Checkout reserves inventory exclusively through
`FastCheck.Sales.Inventory.ReservationLedger.reserve/5`. Paystack, WhatsApp,
ticket issuance, scanner, and mobile runtime remain out of scope.

## Paths Updated

- `lib/fastcheck/sales/checkout.ex`
- `lib/fastcheck/sales/state_transition_support.ex`
- `lib/fastcheck/sales/order.ex`
- `lib/fastcheck/sales/order_line.ex`
- `lib/fastcheck/sales/checkout_session.ex`
- `lib/fastcheck/sales/state_transition.ex`
- `lib/fastcheck/sales/inventory/reservation_ledger.ex` (`hold_key/1` public)
- `config/config.exs` (`:sales_checkout_hold_ttl_seconds`, `:sales_hold_token_pepper`)
- `config/test.exs` (test pepper)
- `priv/repo/migrations/20260616140000_add_internal_pilot_source_channel.exs`
- `test/support/sales_checkout_fixtures.ex`
- `test/fastcheck/sales/order_checkout_core_test.exs`
- `test/fastcheck/sales/checkout_idempotency_test.exs`
- `test/fastcheck/sales/checkout_policy_test.exs`
- `test/fastcheck/sales/checkout_inventory_boundary_test.exs`
- `test/fastcheck/sales/checkout_session_test.exs`
- `test/fastcheck/sales/order_line_snapshot_test.exs`
- `test/fastcheck/sales/order_state_transition_test.exs`
- Boundary/skeleton test updates under `test/fastcheck/sales/`

## Orchestration Contract

`FastCheck.Sales.Checkout.start_checkout/3`:

1. Validates quantity and replays idempotent requests before authorization.
2. Authorizes `system`, `admin`, and `customer_session` actors with event scope.
3. Requires explicit `effective_sales_channel` for `system`/`test` source channels.
4. Loads offers via system `TicketOffer.get_by_id` with explicit error mapping.
5. Creates draft order and immutable line snapshot.
6. Confirms checkout, creates session, reserves inventory, attaches hold, and
   marks order `awaiting_payment`.
7. Stores a hashed opaque `hold_token` (peppered SHA-256), never the raw
   idempotency key.
8. Compensates with `ReservationLedger.release/3` on post-reserve Ash failure;
   moves to `manual_review` when release fails.

## Actions Added

**Order:** `create_draft`, `confirm_checkout`, `mark_awaiting_payment`,
`mark_payment_pending`, `mark_paid_unverified`, `expire_order`, `cancel_order`,
`mark_manual_review`, `get_by_idempotency_key`

**OrderLine:** `create_for_order`, `list_for_order`

**CheckoutSession:** `create_session`, `attach_inventory_hold`,
`mark_payment_link_sent`, `expire_session`, `release_session`, `mark_manual_review`

**StateTransition:** `record_transition`, `list_for_entity`

## Boundaries Preserved

- No Paystack, WhatsApp, ticket issuance, scanner, attendee, or mobile changes.
- No generic `update_status` / `update_state` actions.
- Inventory Redis mutation remains confined to approved inventory modules.

## Verification

- `mix test test/fastcheck/sales/order_checkout_core_test.exs`
- `mix test test/fastcheck/sales/checkout_*_test.exs`
- `mix test test/fastcheck/sales/order_*_test.exs`
- `mix test test/fastcheck/sales/`
- `mix precommit`
