# VS-01D Ticket and Delivery Resource Skeletons

## Purpose

VS-01D adds durable ticket issuance and delivery attempt Ash/Postgres skeletons:

- `FastCheck.Sales.TicketIssue`
- `FastCheck.Sales.DeliveryAttempt`

The slice establishes resource and table shape only. Ticket issuing, QR/token
generation, attendee creation, WhatsApp/email delivery, scanner mutation, Oban
workers, admin UI, and mobile API remain out of scope.

## Accepted Decisions Applied

- Access model: `event_scoped_first`.
- First-release owner boundary: `event_id` on orders (unchanged from VS-01B).
- `organization_id`: deferred. VS-01D tables intentionally do not include an
  `organization_id` column.
- `TicketIssue.status` follows the accepted VS-00A issuance vocabulary only
  (`pending`, `issued`, `revoked`, `manual_review`).
- `DeliveryAttempt.status` follows the accepted VS-00A delivery vocabulary.
- `DeliveryAttempt` is the source of truth for delivery attempt history.
- `TicketIssue.attendee_id` is a nullable external Ecto reference with no Ash
  `belongs_to` to existing `Attendee`.

## Tables

VS-01D creates exactly two additional Sales tables:

- `sales_ticket_issues`
- `sales_delivery_attempts`

Combined with VS-01B and VS-01C, the Sales table inventory through VS-01D is
nine tables.

## Relationships

- `TicketIssue` belongs to `Order` and `OrderLine`.
- `TicketIssue` has many `DeliveryAttempt`.
- `DeliveryAttempt` belongs to `Order` and `TicketIssue`.
- `Order` has many `ticket_issues` and `delivery_attempts`.
- `OrderLine` has many `ticket_issues`.

## Sensitive / Restricted Fields

The following fields must not be logged, displayed in operator UI, or printed
in test failure messages:

- `TicketIssue.ticket_code`
- `TicketIssue.qr_token_hash`
- `TicketIssue.delivery_token_hash`
- `TicketIssue.attendee_id`
- `DeliveryAttempt.recipient`
- `DeliveryAttempt.provider_error_message`
- `DeliveryAttempt.failure_reason`

Ash resources mark these with `sensitive?: true`. Field-level Ash policies land
in VS-01F.

## Boundary

This slice does not add customer, admin, public, scanner, Android, mobile API,
Paystack client/controller, webhook verification, Redis `ReservationLedger`,
Oban workers, QR/token generation, ticket issuer, Tickera, attendee mutation, or
event runtime paths.

No generic `update_status` / `update_state` actions or state-machine workflow
actions are implemented.

`Conversation` and `TicketDeliveryToken` resources are not created.
