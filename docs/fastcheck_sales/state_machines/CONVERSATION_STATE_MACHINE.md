# Conversation State Machine

## Allowed States

`new`, `selecting_language`, `main_menu`, `selecting_event`,
`selecting_ticket_type`, `collecting_quantity`, `collecting_buyer_name`,
`collecting_email`, `confirming_order`, `awaiting_payment`, `payment_pending`,
`payment_received`, `ticket_issued`, `completed`, `manual_review`,
`cancelled`, `expired`.

## Transition Matrix

| From state | To state | Named action | Actor type | Preconditions | Required side effects | Audit required? | Idempotency rule | Terminal? |
|---|---|---|---|---|---|---|---|---|
| `new` | `selecting_language` | `start_language_selection` | `customer_session/system` | Session created and language not known. | Store checkpoint. | yes | Duplicate inbound resumes checkpoint. | no |
| `new` | `main_menu` | `start_default_main_menu` | `customer_session/system` | Default language/session path accepted. | Store checkpoint. | yes | Duplicate inbound resumes checkpoint. | no |
| `new` | `expired` | `expire_new_conversation` | `system` | Session TTL expired. | Persist expiry checkpoint. | yes | Duplicate expiry returns expired. | yes |
| `selecting_language` | `main_menu` | `select_language` | `customer_session` | Valid language option. | Store language and checkpoint. | yes | Same selection idempotent. | no |
| `selecting_language` | `expired` | `expire_language_selection` | `system` | Session TTL expired. | Persist checkpoint. | yes | Duplicate expiry returns expired. | yes |
| `selecting_language` | `manual_review` | `review_language_selection` | `system/admin` | Repeated invalid state or support trigger. | Record handoff reason. | yes | Existing review remains. | no |
| `main_menu` | `selecting_event` | `choose_buy_tickets` | `customer_session` | Buy flow selected. | Show event-scoped options. | yes | Duplicate choice resumes selection. | no |
| `main_menu` | `completed` | `complete_non_purchase_flow` | `customer_session/system` | Non-purchase flow completed. | Store checkpoint. | yes | Duplicate complete returns completed. | yes |
| `main_menu` | `manual_review` | `handoff_main_menu` | `customer_session/system` | Support/handoff selected or required. | Record handoff reason. | yes | Existing review remains. | no |
| `main_menu` | `expired` | `expire_main_menu` | `system` | Session TTL expired. | Store expiry. | yes | Duplicate expiry returns expired. | yes |
| `selecting_event` | `selecting_ticket_type` | `select_event` | `customer_session` | Event is sellable and visible. | Store event_id checkpoint. | yes | Same event choice idempotent. | no |
| `selecting_event` | `main_menu` | `return_to_main_menu_from_event` | `customer_session` | Customer cancels event selection. | Preserve safe checkpoint. | yes | Duplicate return idempotent. | no |
| `selecting_ticket_type` | `collecting_quantity` | `select_ticket_type` | `customer_session` | Offer is sellable and event-scoped. | Store offer checkpoint. | yes | Same offer choice idempotent. | no |
| `collecting_quantity` | `collecting_buyer_name` | `submit_quantity` | `customer_session` | Quantity is valid for offer policy. | Store quantity checkpoint. | yes | Same quantity idempotent. | no |
| `collecting_buyer_name` | `collecting_email` | `submit_buyer_name` | `customer_session` | Name passes validation. | Store PII according to policy. | yes | Same value update idempotent. | no |
| `collecting_buyer_name` | `confirming_order` | `skip_optional_email_after_name` | `customer_session` | Email optional for selected flow. | Store checkpoint. | yes | Same skip idempotent. | no |
| `collecting_email` | `confirming_order` | `submit_buyer_email` | `customer_session` | Email valid or accepted optional. | Store PII according to policy. | yes | Same email idempotent. | no |
| `confirming_order` | `awaiting_payment` | `confirm_order` | `customer_session` | Order details confirmed; Sales core creates checkout. | Call Sales/Checkout service; do not mutate Redis directly. | yes | Same confirmation returns existing checkout. | no |
| `confirming_order` | `main_menu` | `cancel_order_confirmation` | `customer_session` | Customer chooses back/cancel. | Release any unconfirmed hold if created. | yes | Duplicate cancel idempotent. | no |
| `confirming_order` | `cancelled` | `cancel_confirmed_flow` | `customer_session/system` | Customer cancels and no verified payment exists. | Release hold if present. | yes | Duplicate cancel returns cancelled. | yes |
| `confirming_order` | `expired` | `expire_order_confirmation` | `system` | Session/hold TTL expired. | Release hold if present. | yes | Duplicate expiry returns expired. | yes |
| `awaiting_payment` | `payment_pending` | `mark_conversation_payment_pending` | `system` | Payment URL sent or customer starts payment. | Send truthful pending message. | yes | Duplicate pending returns pending. | no |
| `awaiting_payment` | `payment_received` | `mark_conversation_payment_received` | `system` | Durable verified payment exists. | Send truthful received/pending-fulfillment message. | yes | Duplicate received returns received. | no |
| `awaiting_payment` | `manual_review` | `handoff_awaiting_payment` | `system/admin` | Payment state ambiguous or support required. | Record handoff reason. | yes | Existing review remains. | no |
| `awaiting_payment` | `expired` | `expire_awaiting_payment_conversation` | `system` | Session expired and no durable verified payment exists. | Send safe expiry message if allowed. | yes | Duplicate expiry returns expired. | yes |
| `payment_pending` | `payment_received` | `confirm_pending_payment_received` | `system` | Durable verified payment exists. | Send truthful received message. | yes | Duplicate received returns received. | no |
| `payment_pending` | `ticket_issued` | `confirm_pending_ticket_issued` | `system` | Ticket issuance completed. | Send secure ticket link or delivery status. | yes | Duplicate issued returns issued. | no |
| `payment_pending` | `manual_review` | `handoff_payment_pending` | `system/admin` | Payment exists but fulfillment unsafe. | Send safe support/pending message. | yes | Existing review remains. | no |
| `payment_received` | `ticket_issued` | `mark_conversation_ticket_issued` | `system` | Ticket issued and delivery path available. | Send secure ticket delivery status. | yes | Duplicate issued returns issued. | no |
| `payment_received` | `manual_review` | `handoff_payment_received` | `system/admin` | Fulfillment cannot safely complete. | Send safe pending/support message. | yes | Existing review remains. | no |
| `ticket_issued` | `completed` | `complete_ticket_conversation` | `system/customer_session` | Delivery complete or customer flow complete. | Store completion checkpoint. | yes | Duplicate complete returns completed. | yes |
| `ticket_issued` | `manual_review` | `handoff_ticket_issued` | `admin/system` | Support issue requires review. | Record reason. | yes | Existing review remains. | no |
| `manual_review` | approved target | `resolve_conversation_review` | `admin/system` | Target and reason approved. | Send customer-safe message if needed. | yes | Resolution idempotent by review id. | target-dependent |

## Rules

- Afrikaans-first number-only flow remains the default UX direction.
- Redis hot state may expire, but Postgres checkpoints must prevent customer
  confusion.
- Conversation code must call Sales/Checkout services; it must not own
  inventory, payment authority, ticket issuance, or scanner validity.
