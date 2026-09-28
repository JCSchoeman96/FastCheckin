# DeliveryAttempt State Machine

## Allowed States

`queued`, `dispatching`, `provider_accepted`, `sent`, `delivered`, `read`,
`provider_failed`, `failed`, `fallback_required`, `cancelled`, `manual_review`.

## Relationship to TicketDeliveryIntent

`TicketDeliveryIntent` is the logical customer-delivery identity. Each
`DeliveryAttempt` is one provider transport attempt beneath that intent. A safe
local transport retry creates another attempt with the next `attempt_number`
under the same intent. Payment-link attempts may have no intent. Existing
historical `delivery_reason = NULL` rows remain unchanged; new initial ticket
delivery attempts use `initial_ticket_delivery`, and verified resend attempts
use `verified_ticket_resend`.

## Transition Matrix

| From state | To state | Named action | Actor type | Preconditions | Required side effects | Audit required? | Idempotency rule | Terminal? |
|---|---|---|---|---|---|---|---|---|
| `queued` | `dispatching` | `mark_dispatching` | `system` | Durable intent authority and ticket relationships validate. | Commit one attempt allocation before calling the provider. | yes | Intent row lock serializes attempt allocation. | no |
| `dispatching` | `provider_accepted` | `mark_provider_accepted` | `system` | Provider returned a valid message ID. | Store provider message ID and acceptance time. | yes | Existing accepted evidence prevents another send. | no |
| `provider_accepted` | `sent` | `mark_delivery_sent` | `system` | Provider status evidence reports sent. | Update provider lifecycle evidence. | yes | Duplicate callback is idempotent. | no |
| `sent` | `delivered` | `mark_delivery_delivered` | `system` | Provider delivery receipt accepted. | Record delivered_at. | yes | Duplicate receipt returns delivered. | no |
| `delivered` | `read` | `mark_delivery_read` | `system` | Provider read receipt accepted. | Record read_at. | yes | Duplicate receipt returns read. | yes |
| `queued` | `failed` | `fail_queued_delivery` | `system` | Provider/client rejects send. | Store safe provider error code/message. | yes | Duplicate failure preserves first reason. | conditional |
| `queued` | `fallback_required` | `mark_queued_delivery_fallback_required` | `system` | Channel unavailable or WhatsApp window closed. | Record fallback reason. | yes | Existing fallback remains. | no |
| `queued` | `cancelled` | `cancel_queued_delivery` | `admin/system` | Ticket/order no longer deliverable. | Record reason. | yes | Duplicate cancel returns cancelled. | yes |
| `sent` | `delivered` | `mark_delivery_delivered` | `system` | Provider delivery receipt accepted. | Record delivered_at. | yes | Duplicate receipt returns delivered. | yes |
| `sent` | `failed` | `fail_sent_delivery` | `system` | Provider reports failed delivery. | Store safe failure reason. | yes | Duplicate failure preserves prior delivered state if delivered exists. | conditional |
| `sent` | `fallback_required` | `mark_sent_delivery_fallback_required` | `system` | Delivery cannot complete on current channel. | Record fallback reason. | yes | Existing fallback remains. | no |
| `failed` | `fallback_required` | `require_delivery_fallback` | `system/admin` | Retry on current channel is not safe or exhausted. | Record fallback path. | yes | Existing fallback remains. | no |
| `failed` | `manual_review` | `review_failed_delivery` | `admin/system` | Support decision required. | Record reason. | yes | Existing review remains. | no |
| `failed` | `cancelled` | `cancel_failed_delivery` | `admin/system` | Delivery should not continue. | Record reason. | yes | Duplicate cancel returns cancelled. | yes |
| `fallback_required` | `queued` | `queue_fallback_delivery` | `system/admin` | Approved fallback/template path exists. | Create next delivery attempt link. | yes | Same fallback idempotent by correlation_id. | no |
| `fallback_required` | `failed` | `fail_delivery_fallback` | `system` | Fallback cannot be queued or sent. | Store safe reason. | yes | Duplicate failure preserves reason. | conditional |
| `fallback_required` | `manual_review` | `review_delivery_fallback` | `admin/system` | Fallback needs support action. | Record reason. | yes | Existing review remains. | no |
| `manual_review` | approved target | `resolve_delivery_review` | `admin/system` | Target and reason approved. | Run target side effects. | yes | Resolution idempotent by review id. | target-dependent |

## Rules

- A `provider_accepted` TicketDeliveryIntent ends automatic sending. Later Meta
  evidence remains on its `DeliveryAttempt` rows.
- An unresolved `dispatching` attempt after process recovery is ambiguous and
  moves the attempt and intent to `manual_review`; it is not automatically
  resent.
- Redis WhatsApp dedupe is an optimization only. PostgreSQL intent identity and
  attempt history decide whether an initial ticket send may run.
- A failed session message must not silently disappear.
- If the WhatsApp 24-hour customer-service window is closed, use an approved
  utility template or fallback policy.
- Failed resend must not erase or overwrite earlier successful delivery evidence.
