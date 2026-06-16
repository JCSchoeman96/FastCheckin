# VS-05A Secondary Sales Entry Points

## Status

Implemented thin admin-assisted and internal-pilot checkout entrypoints over the
VS-05 checkout core.

## Scope

In scope:

- `FastCheck.Sales.SecondaryEntrypoints` adapter boundary
- `FastCheckWeb.Sales.AdminCheckoutLive`
- `FastCheckWeb.Sales.InternalPilotCheckoutLive`
- Dashboard-authenticated routes:
  - `/dashboard/sales/checkout/:event_id`
  - `/dashboard/sales/internal-pilot/checkout/:event_id`
- `:sales_internal_pilot_enabled` config (`SALES_INTERNAL_PILOT_ENABLED` in runtime)
- Session-scoped idempotency keys in LiveView assigns
- Adapter, policy, boundary, and log-redaction tests

Out of scope (deferred):

- Public web checkout (`web_checkout_sales`)
- Paystack, WhatsApp, ticket issuance, attendees, scanner/mobile changes
- Post-merge implementation handoff (created after merge only)

## Contracts

- All checkout creation calls `FastCheck.Sales.Checkout.start_checkout/3` through
  `SecondaryEntrypoints` only.
- `source_channel` is mapped server-side (`admin`, `internal_pilot`).
- Client params cannot spoof `source_channel` or trusted `idempotency_key`.
- LiveView mounts generate one idempotency key; retries/errors keep it; success
  or explicit reset rotates it.
- Offer display uses Ash read `:list_active_for_event` with channel filters.
- Invalid event IDs redirect safely (no 500 from missing events).

## Paths

- `lib/fastcheck/sales/secondary_entrypoints.ex`
- `lib/fastcheck_web/live/sales/admin_checkout_live.ex`
- `lib/fastcheck_web/live/sales/internal_pilot_checkout_live.ex`
- `lib/fastcheck_web/router.ex`
- `config/config.exs`, `config/runtime.exs`, `config/test.exs`
- `test/fastcheck/sales/secondary_entrypoints_test.exs`
- `test/fastcheck_web/sales/*`
- `test/support/sales_web_fixtures.ex`
- `test/support/sales_boundary_allowlist.ex`
