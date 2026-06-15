# VS-01A Ash Installation and Sales Domain Shell

## Purpose

Install Ash 3.x and AshPostgres, register the empty `FastCheck.Sales` Ash
domain, and document the boundary for later Sales implementation slices.

## Scope

In scope:

- Ash 3.x dependency.
- AshPostgres dependency.
- `FastCheck.Sales` domain registration through `:ash_domains`.
- Empty `FastCheck.Sales` Ash domain shell.
- Domain-shell tests proving the domain exists and has no resources.

Out of scope:

- Ash resources.
- Sales database migrations or `sales_*` tables.
- Redis inventory behavior.
- Paystack behavior.
- Meta/WhatsApp behavior.
- QR, delivery-token, ticket-code, or ticket-issuer behavior.
- Attendee, event, scanner, Tickera sync, Android/mobile API, LiveView, route,
  or Oban changes.

## Boundary

`FastCheck.Sales` is the future durable Sales domain boundary. In VS-01A it has
zero registered resources and no persistence behavior of its own.

Later slices may add Sales resources only when their feature packs explicitly
allow them. Existing scanner-compatible ticket and attendee behavior remains on
the current Ecto/runtime paths until a future approved slice changes that
contract.

## Acceptance Notes

- `FastCheck.Sales` is registered in application config under `:ash_domains`.
- `FastCheck.Sales` has an empty resource list.
- No `lib/fastcheck/sales/*.ex` resource files are created.
- No `priv/repo/migrations/*sales*.exs` migrations are created.
- No runtime Sales channel, payment, inventory, delivery, or scanner behavior is
  added.
