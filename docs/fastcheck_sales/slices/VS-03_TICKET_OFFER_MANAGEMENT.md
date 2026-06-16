# VS-03 Ticket Offer Management

## Status

Implemented as durable TicketOffer management for FastCheck Sales.

## Scope

VS-03 adds named `FastCheck.Sales.TicketOffer` actions for admin-managed offer
configuration, controlled active-offer reads, and centralized offer cache
invalidation.

TicketOffer remains durable configuration only. Live inventory, reservations,
checkout, and payment behavior remain out of scope.

## Paths Updated

- `lib/fastcheck/sales/ticket_offer.ex`
- `lib/fastcheck/sales/policy_checks.ex`
- `lib/fastcheck/sales/offers/cache_invalidation.ex`
- `priv/repo/migrations/20260616102500_allow_nullable_sales_ticket_offer_windows.exs`
- `test/fastcheck/sales/ticket_offer_test.exs`
- `test/fastcheck/sales/ticket_offer_policy_test.exs`
- `test/fastcheck/sales/ticket_offer_cache_invalidation_test.exs`
- `test/fastcheck/sales/ticket_offer_boundary_test.exs`
- `test/fastcheck/sales/core_resource_skeletons_test.exs`

## Actions Added

- `create_offer`
- `update_offer`
- `enable_sales`
- `disable_sales`
- `list_active_for_event`
- `get_available_for_checkout`

## Validation and Policy Rules

- Admin-only mutate actions (`create_offer`, `update_offer`, `enable_sales`,
  `disable_sales`) with event scoping.
- Operator remains read-only.
- `customer_session` remains blocked from broad reads and can access only
  controlled actions (`list_active_for_event`, `get_available_for_checkout`)
  with event scoping.
- `price_cents`, `currency`, quantity bounds, `sales_channel`, and offer-window
  checks are enforced by Ash validations and DB constraints.

## Data Contract Changes

Migration `20260616102500_allow_nullable_sales_ticket_offer_windows.exs`:

- makes `sales_ticket_offers.starts_at` nullable
- makes `sales_ticket_offers.ends_at` nullable
- adds `sales_ticket_offers_sales_channel_valid` check constraint
- adds `sales_ticket_offers_window_valid` check constraint
- adds `sales_ticket_offers_max_per_order_within_configured` check constraint

This aligns VS-03 with open-ended windows:

- `starts_at IS NULL OR starts_at <= as_of`
- `ends_at IS NULL OR ends_at > as_of`

## Cache Invalidation Boundary

`FastCheck.Sales.Offers.CacheInvalidation.invalidate_event_offers/1` is the
single mutation-side boundary for offer cache invalidation.

Current behavior:

- invalidates CacheManager keys matching event-offer patterns

Explicitly out of scope:

- Redis live inventory writes
- ReservationLedger operations
- checkout or payment side effects

## Boundary Confirmation

VS-03 does not add or modify:

- Redis inventory authority
- ReservationLedger
- checkout/orders runtime flows
- Paystack or WhatsApp/Meta integrations
- ticket issuance
- attendee/scanner/mobile/Android surfaces
- UI or routing surfaces
