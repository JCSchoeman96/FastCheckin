# DeliveryAttempt State Machine

## Allowed States

`queued`, `sent`, `delivered`, `failed`, `fallback_required`, `cancelled`,
`manual_review`.

## Transition Matrix

| From state | To state | Named action | Actor type | Preconditions | Required side effects | Audit required? | Idempotency rule | Terminal? |
|---|---|---|---|---|---|---|---|---|
| `queued` | `sent` | `mark_delivery_sent` | `system` | Provider accepted message/send request. | Store provider_message_id safely. | yes | Same correlation_id returns existing sent attempt. | no |
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

- A failed session message must not silently disappear.
- If the WhatsApp 24-hour customer-service window is closed, use an approved
  utility template or fallback policy.
- Failed resend must not erase or overwrite earlier successful delivery evidence.
