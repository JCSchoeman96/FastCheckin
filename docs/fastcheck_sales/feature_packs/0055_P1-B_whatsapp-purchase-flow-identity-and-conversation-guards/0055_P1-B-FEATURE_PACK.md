# P1-B WhatsApp purchase identity and Conversation guards

## Goal

Give each genuine WhatsApp Buy flow its own checkout identity, keep durable
commercial Orders attached to their Conversation through restart and navigation,
and make named Conversation actions enforce their documented source states.

## Identity boundaries

These values have separate scopes:

```text
provider_message_id
  inbound-message idempotency

purchase_flow_id
  one genuine WhatsApp purchase attempt; opaque UUID

Order.idempotency_key
  durable checkout identity derived from purchase_flow_id
```

The UUID is created by `choose_buy_tickets` on the transition from `main_menu`
to `selecting_event`. Duplicate inbound delivery, selection changes, Back within
the flow, confirmation retry, offer refresh, and payment initialization retry
retain it. A new Buy flow creates a fresh UUID. Resend does not create or use a
purchase identity.

New checkouts use:

```text
whatsapp:conversation:<conversation_id>:purchase:<purchase_flow_id>:checkout
```

An in-flight pre-P1-B Conversation without `purchase_flow_id` keeps using:

```text
whatsapp:conversation:<conversation_id>:checkout
```

The legacy key is checked before creating a checkout. Confirmation does not
invent a UUID for that historical purchase. A later new Buy flow receives a
modern UUID and key.

`Conversation.state_data` is the durable UUID store. The existing Redis
SessionStore hash includes the UUID as a bounded hot projection with the
existing WhatsApp session TTL. `Order.idempotency_key` permanently preserves
the checkout identity. No PurchaseFlow table, schema migration, Redis key
family, or generic Checkout change is part of this slice.

## Active Order guard

`sales_orders.sales_conversation_id` is the authoritative Conversation
relationship. The bounded lookup checks an explicit `sales_order_id`, the
modern purchase key or historical legacy key, and then up to two active Orders
through the indexed Conversation foreign key. A mismatch or multiple active
Orders fails closed; the runtime never picks the latest Order.

An active Order preserves state and blocks restart, Stop, Back, new Buy, and
Resend. The response comes from the durable Order status. An uncheckpointed
Order can repair `sales_order_id` and `order_public_reference` only when the
relationship is unambiguous. The repair does not infer a PaymentAttempt.

Restart behavior is:

- **Pre-commercial flow:** Restart may reset the current flow and clear its
  `purchase_flow_id`.
- **Active commercial Order:** Restart may not abandon the Order or clear its
  association. The customer gets payment, fulfillment, or support guidance.
- **Terminal/completed Order:** Restart may clear the old Conversation
  checkpoint. The historical Order remains linked. The next Buy gets a new
  `purchase_flow_id`.

The Order resource defines these active statuses:

```text
draft
awaiting_payment
payment_pending
paid_unverified
paid_verified
fulfillment_queued
partially_issued
issuance_retry_queued
manual_review
manual_review_held
```

The guard treats `ticket_issued`, `expired`, `cancelled`, `refunded`, and
`no_fulfillment_closed` as terminal. `manual_review` and
`manual_review_held` block another purchase.

## Conversation transition matrix

The resource owns one central named-action map from action to `allowed_from`
states and a target. Every state-changing action validates its source state
before recording its transition audit. Direct Ash action calls enforce the
same matrix; dispatch-only checks are not sufficient.

The intentional self-transitions are limited to menu refresh from
`selecting_event` and `selecting_ticket_type`, and payment-pending checkpoint
refresh from `payment_pending`. Other actions cannot transition from their
target state by default. `restart_to_main_menu` is a distinct action guarded by
the durable active Order lookup.

See
[`CONVERSATION_STATE_MACHINE.md`](../../state_machines/CONVERSATION_STATE_MACHINE.md)
for the complete matrix and identity/restart rules.

## Verification coverage

The slice covers direct named-action acceptance and rejection, modern and
legacy Order lookup, duplicate confirmation, restart/Stop/Back with committed
Orders, historical cleared main-menu recovery, multiple active Orders,
SessionStore projection, and an issued-order then second-purchase flow using the
same durable Conversation.

Generic Checkout continues to accept an opaque idempotency key. WhatsApp derives
that key at its adapter boundary.

## Out of scope

- Refunds, restocking, wallets, or another payment authority.
- A PurchaseFlow database resource or migration.
- New checkout implementation or WhatsApp logic in generic Checkout.
- A new resend identity or resend challenge behavior.
