# Conversation State Machine

## Allowed States

`new`, `selecting_language`, `main_menu`, `selecting_event`,
`selecting_ticket_type`, `collecting_quantity`, `collecting_buyer_name`,
`collecting_email`, `confirming_order`, `awaiting_payment`, `payment_pending`,
`payment_received`, `ticket_issued`, `completed`, `manual_review`, `cancelled`,
`expired`, `collecting_resend_name`, `collecting_resend_email`,
`collecting_resend_otp`, `awaiting_verified_resend_delivery`,
`verified_resend_delivery_queued`.

## Named Transition Matrix

`FastCheck.Sales.Conversation` validates these `allowed_from` lists at the Ash
resource action boundary. Direct action calls receive the same checks as calls
through `ConversationStateMachine`.

| Named action | Allowed source states | Target state |
|---|---|---|
| `start_language_selection` | `new` | `selecting_language` |
| `start_default_main_menu` | `new` | `main_menu` |
| `select_language` | `selecting_language` | `main_menu` |
| `choose_buy_tickets` | `main_menu` | `selecting_event` |
| `choose_resend_ticket` | `main_menu` | `collecting_resend_name` |
| `select_event` | `selecting_event` | `selecting_ticket_type` |
| `select_ticket_type` | `selecting_ticket_type` | `collecting_quantity` |
| `submit_quantity` | `collecting_quantity` | `collecting_buyer_name` |
| `submit_buyer_name` | `collecting_buyer_name` | `collecting_email` |
| `submit_buyer_email` | `collecting_email` | `confirming_order` |
| `skip_optional_email_after_name` | `collecting_email` | `confirming_order` |
| `confirm_order` | `confirming_order` | `awaiting_payment` |
| `submit_resend_name` | `collecting_resend_name` | `collecting_resend_email` |
| `submit_resend_email` | `collecting_resend_email` | `collecting_resend_otp` |
| `verify_resend_otp` | `collecting_resend_otp` | `awaiting_verified_resend_delivery` |
| `queue_verified_resend_delivery` | `awaiting_verified_resend_delivery` | `verified_resend_delivery_queued` |
| `return_to_event_selection` | `selecting_event`, `selecting_ticket_type`, `collecting_quantity`, `confirming_order` | `selecting_event` |
| `return_to_ticket_type_selection` | `selecting_ticket_type`, `collecting_quantity`, `confirming_order` | `selecting_ticket_type` |
| `return_to_quantity_collection` | `collecting_buyer_name`, `confirming_order` | `collecting_quantity` |
| `return_to_buyer_name_collection` | `collecting_email` | `collecting_buyer_name` |
| `return_to_email_collection` | `confirming_order` | `collecting_email` |
| `return_to_resend_name_collection` | `collecting_resend_email` | `collecting_resend_name` |
| `return_to_resend_email_collection` | `collecting_resend_otp` | `collecting_resend_email` |
| `return_to_main_menu` | `selecting_event`, `selecting_ticket_type`, `collecting_quantity`, `confirming_order`, `collecting_resend_name` | `main_menu` |
| `restart_to_main_menu` | `new`, `selecting_language`, `main_menu`, `selecting_event`, `selecting_ticket_type`, `collecting_quantity`, `collecting_buyer_name`, `collecting_email`, `confirming_order`, `awaiting_payment`, `payment_pending`, `payment_received`, `ticket_issued`, `completed`, `manual_review`, `cancelled`, `expired`, `collecting_resend_name`, `collecting_resend_email`, `collecting_resend_otp`, `awaiting_verified_resend_delivery`, `verified_resend_delivery_queued` | `main_menu` |
| `cancel_conversation` | `new`, `selecting_language`, `main_menu`, `selecting_event`, `selecting_ticket_type`, `collecting_quantity`, `collecting_buyer_name`, `collecting_email`, `confirming_order`, `collecting_resend_name`, `collecting_resend_email`, `collecting_resend_otp`, `awaiting_verified_resend_delivery`, `verified_resend_delivery_queued` | `cancelled` |
| `handoff_conversation` | `new`, `selecting_language`, `main_menu`, `selecting_event`, `selecting_ticket_type`, `collecting_quantity`, `collecting_buyer_name`, `collecting_email`, `confirming_order`, `awaiting_payment`, `payment_pending`, `payment_received`, `ticket_issued`, `collecting_resend_name`, `collecting_resend_email`, `collecting_resend_otp`, `awaiting_verified_resend_delivery`, `verified_resend_delivery_queued` | `manual_review` |
| `mark_conversation_payment_pending` | `confirming_order`, `main_menu`, `awaiting_payment`, `payment_pending` | `payment_pending` |
| `request_payment_email` | `confirming_order`, `main_menu`, `awaiting_payment`, `payment_pending` | `collecting_email` |

The explicit self-transitions are `return_to_event_selection` from
`selecting_event`, `return_to_ticket_type_selection` from
`selecting_ticket_type`, and `mark_conversation_payment_pending` from
`payment_pending`. The first two refresh current menus after catalog or sales
availability changes. The last refreshes a payment checkpoint on a repeated
status or payment-link request. No other action accepts its target state as a
source state.

The runtime uses `return_to_event_selection` from `selecting_event` and
`return_to_ticket_type_selection` from `selecting_ticket_type` to refresh a
menu when its current event or offer becomes unavailable. These self-paths
were added to the earlier documented matrix because they are exercised by the
current menu refresh behavior.

`completed`, `cancelled`, and `expired` are terminal for ordinary actions.
`restart_to_main_menu` is the explicit new-session path. It does not authorize
reset while an active commercial Order exists.

## WhatsApp Identity Boundaries

These identities serve separate purposes:

- `provider_message_id` deduplicates one inbound provider message.
- `purchase_flow_id` is a random opaque UUID for one genuine WhatsApp Buy flow.
- `Order.idempotency_key` is the durable checkout identity derived from that
  purchase flow.

The UUID is created when `choose_buy_tickets` moves from `main_menu` to
`selecting_event`. It is stored in durable `Conversation.state_data` and copied
to the bounded Redis hot-session projection. Redis does not own the identity.
Event, offer, quantity, buyer detail, confirmation, retry, and Back navigation
within that purchase retain the UUID. Starting another Buy flow creates a new
UUID. Resend does not create or reuse a purchase identity.

New checkouts use:

```text
whatsapp:conversation:<conversation_id>:purchase:<purchase_flow_id>:checkout
```

An in-flight Conversation created before this identity existed has no
`purchase_flow_id`; its confirmation continues to use the legacy key:

```text
whatsapp:conversation:<conversation_id>:checkout
```

The legacy identity is checked before a new checkout is created. It is not
assigned to a fresh Buy flow.

## Commercial Order Restart Guards

The durable `sales_orders.sales_conversation_id` relationship is the safety
net. Order lookup is bounded to two active rows so the runtime can distinguish
none, one, and multiple active Orders without scanning phone numbers or
Conversation JSON history. Explicit `sales_order_id` and the current purchase
identity are checked first; a Conversation-level active Order query repairs
historical cleared checkpoints.

The non-abandonable Order states are:

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

`ticket_issued`, `expired`, `cancelled`, `refunded`, and `no_fulfillment_closed`
are safe for a new Conversation purchase flow. The first four are the customer
purchase lifecycle terminal states; `no_fulfillment_closed` is the Order
resource's additional terminal review-closure state.

Restart rules:

- **Pre-commercial flow:** `#` may clear the current purchase or resend flow
  and return to `main_menu`. A later Buy starts with a new purchase UUID.
- **Active commercial Order:** `#`, `stop`, Back, Buy, and Resend do not clear
  the Order association or start another flow. The customer receives a status
  or support response from the durable Order state. Multiple active Orders
  fail closed to support; the runtime never chooses the newest or oldest.
- An active commercial Order also dominates messages in a Conversation already
  inside Resend (`collecting_resend_name`, `collecting_resend_email`,
  `collecting_resend_otp`, `awaiting_verified_resend_delivery`, or
  `verified_resend_delivery_queued`). This is a valid historical state from
  the pre-P1-B Restart bug, which could clear an active purchase before the
  customer entered Resend. The active-order check runs before resend OTP
  creation or verification and before delivery enqueue. The message receives
  the existing payment, fulfillment, or support response, and Resend does not
  advance.
- **Terminal/completed Order:** Restart may clear the old Conversation
  checkpoint. Historical Orders remain linked to the Conversation. The next
  Buy receives a new purchase UUID and checkout key.

An uncheckpointed active Order can safely repair `sales_order_id` and
`order_public_reference` when the relationship is unambiguous. The runtime does
not infer `payment_attempt_id` during this repair.

## Rules

- Redis is an expiring projection; PostgreSQL Conversation and Order records
  are durable authority.
- Conversation code calls Sales and Checkout services. It does not own
  inventory, payment authority, ticket issuance, or scanner validity.
- Never log buyer PII, payment URLs, or payment tokens.
