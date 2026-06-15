# VS-01B Core Sales Resource Skeletons

## Purpose

VS-01B adds the first durable FastCheck Sales Ash/Postgres skeletons:

- `FastCheck.Sales.TicketOffer`
- `FastCheck.Sales.Order`
- `FastCheck.Sales.OrderLine`
- `FastCheck.Sales.StateTransition`

The slice establishes resource and table shape only. Checkout, payment,
inventory, WhatsApp, ticket issuance, delivery, admin UI, scanner, mobile API,
and workflow actions remain out of scope.

## Accepted Decisions Applied

- Access model: `event_scoped_first`.
- First-release owner boundary: `event_id`.
- `organization_id`: deferred. These tables intentionally do not include an
  `organization_id` column until a future tenant-isolation slice defines the
  organization and membership model.
- Money fields use integer cents.
- `Order.status` follows the accepted VS-00A order-state vocabulary.
- `StateTransition` is append-only at the skeleton level. No transition helper,
  update action, destroy action, or generic status mutation is implemented.

## Tables

VS-01B creates exactly four Sales tables:

- `sales_ticket_offers`
- `sales_orders`
- `sales_order_lines`
- `sales_state_transitions`

## Boundary

This slice does not add customer, admin, public, scanner, Android, mobile API,
Paystack, Meta/WhatsApp, Redis, Oban, QR/token, ticket issuer, Tickera, attendee,
or event runtime paths.

PII-bearing order fields exist only as durable columns in the Sales core
skeleton. No route, LiveView, controller, worker, log call, or public access path
is added for those fields in VS-01B.
