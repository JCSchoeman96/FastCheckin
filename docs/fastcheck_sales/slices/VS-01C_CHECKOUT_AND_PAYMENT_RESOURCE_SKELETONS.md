# VS-01C Checkout and Payment Resource Skeletons

## Purpose

VS-01C adds durable checkout and payment Ash/Postgres skeletons:

- `FastCheck.Sales.CheckoutSession`
- `FastCheck.Sales.PaymentAttempt`
- `FastCheck.Sales.PaymentEvent`

The slice establishes resource and table shape only. Checkout workflow, Redis
inventory mutation, Paystack HTTP, webhook processing, Oban workers, ticket
issuance, delivery, admin UI, scanner, and mobile API remain out of scope.

## Accepted Decisions Applied

- Access model: `event_scoped_first`.
- First-release owner boundary: `event_id` on orders (unchanged from VS-01B).
- `organization_id`: deferred. VS-01C tables intentionally do not include an
  `organization_id` column.
- Money fields use integer cents.
- `CheckoutSession.status`, `PaymentAttempt.status`, and
  `PaymentEvent.processing_status` follow accepted VS-00A vocabularies.
- `CheckoutSession` may store `redis_hold_key` and hold metadata only. Redis
  remains the future hot inventory authority; this slice does not mutate Redis.
- Sensitive provider fields use Ash `sensitive?: true` where applicable.

## Tables

VS-01C creates exactly three additional Sales tables:

- `sales_checkout_sessions`
- `sales_payment_attempts`
- `sales_payment_events`

Combined with VS-01B, the Sales table inventory through VS-01C is seven tables.

## Relationships

- `CheckoutSession` belongs to `Order` (`sales_order_id`, unique per order).
- `PaymentAttempt` belongs to `Order` (`sales_order_id`).
- `PaymentEvent` has no foreign key to `PaymentAttempt` so unmatched or early
  webhooks can be stored durably.

## Sensitive Fields

The following fields are stored for future processing/audit only. They must not
be logged, displayed in operator UI, or printed in test failure messages:

- `PaymentAttempt.authorization_url`
- `PaymentAttempt.access_code`
- `PaymentAttempt.raw_initialize_response`
- `PaymentAttempt.raw_verify_response`
- `PaymentEvent.raw_payload`
- `CheckoutSession.hold_token`

Field-level Ash policies land in VS-01F.

## Boundary

This slice does not add customer, admin, public, scanner, Android, mobile API,
Paystack client/controller, webhook verification, Redis `ReservationLedger`,
Oban workers, QR/token generation, ticket issuer, Tickera, attendee, or event
runtime paths.

No generic `update_status` / `update_state` actions or state-machine workflow
actions are implemented.
