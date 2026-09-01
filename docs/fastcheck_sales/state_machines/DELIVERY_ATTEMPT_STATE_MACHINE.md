# DeliveryAttempt State Machine

## Allowed States

`queued`, `provider_accepted`, `sent`, `delivered`, `read`, `failed`,
`fallback_required`, `cancelled`, `manual_review`.

## Transition Matrix

| From state | To state | Named action | Actor type | Preconditions | Required side effects | Audit required? | Idempotency rule | Terminal? |
|---|---|---|---|---|---|---|---|---|
| `queued` | `provider_accepted` | `mark_provider_accepted` | `system` | Meta HTTP API returns a provider message ID. | Store provider_message_id and provider acceptance timestamp. This is not delivery evidence. | yes | Same correlation_id returns the existing accepted attempt. | no |
| `provider_accepted` | `sent` | `reconcile_provider_status` | `system` | Signed, WABA/phone-scoped Meta status callback for the same WAMID. | Store provider status and provider timestamp; set sent_at. | yes | Duplicate or older evidence is a no-op. | no |
| `queued` | `failed` | `fail_queued_delivery` | `system` | Provider/client rejects send. | Store safe provider error code/message. | yes | Duplicate failure preserves first reason. | conditional |
| `queued` | `fallback_required` | `mark_queued_delivery_fallback_required` | `system` | Channel unavailable or WhatsApp window closed. | Record fallback reason. | yes | Existing fallback remains. | no |
| `queued` | `cancelled` | `cancel_queued_delivery` | `admin/system` | Ticket/order no longer deliverable. | Record reason. | yes | Duplicate cancel returns cancelled. | yes |
| `sent` | `delivered` | `reconcile_provider_status` | `system` | Signed, WABA/phone-scoped Meta status callback for the same WAMID. | Record delivered_at and provider timestamp. | yes | Duplicate or older evidence is a no-op. | no |
| `delivered` | `read` | `reconcile_provider_status` | `system` | Signed, WABA/phone-scoped Meta status callback for the same WAMID. | Record read_at and provider timestamp. | yes | Duplicate or older evidence is a no-op. | yes |
| `sent` | `failed` | `reconcile_provider_status` | `system` | Meta reports a failed status, or the provider boundary definitively rejects the request. | Store safe failure reason and provider timestamp. | yes | Older failure cannot regress delivered/read evidence. | conditional |
| `provider_accepted` | `failed` | `reconcile_provider_status` | `system` | Meta reports a failed status. | Store safe failure reason and provider timestamp. | yes | Duplicate failure is a no-op. | conditional |
| `sent` | `fallback_required` | `mark_sent_delivery_fallback_required` | `system` | Delivery cannot complete on current channel. | Record fallback reason. | yes | Existing fallback remains. | no |
| `failed` | `manual_review` | `reconcile_provider_status` | `system` | Later contradictory success evidence or an ambiguous transport outcome. | Preserve evidence and record manual-review reason; do not auto-send. | yes | Same evidence is idempotent. | yes |
| `failed` | `fallback_required` | `require_delivery_fallback` | `system/admin` | Retry on current channel is not safe or exhausted. | Record fallback path. | yes | Existing fallback remains. | no |
| `failed` | `manual_review` | `review_failed_delivery` | `admin/system` | Support decision required. | Record reason. | yes | Existing review remains. | no |
| `failed` | `cancelled` | `cancel_failed_delivery` | `admin/system` | Delivery should not continue. | Record reason. | yes | Duplicate cancel returns cancelled. | yes |
| `fallback_required` | `queued` | `queue_fallback_delivery` | `system/admin` | Approved fallback/template path exists. | Create next delivery attempt link. | yes | Same fallback idempotent by correlation_id. | no |
| `fallback_required` | `failed` | `fail_delivery_fallback` | `system` | Fallback cannot be queued or sent. | Store safe reason. | yes | Duplicate failure preserves reason. | conditional |
| `fallback_required` | `manual_review` | `review_delivery_fallback` | `admin/system` | Fallback needs support action. | Record reason. | yes | Existing review remains. | no |
| `manual_review` | approved target | `resolve_delivery_review` | `admin/system` | Target and reason approved. | Run target side effects. | yes | Resolution idempotent by review id. | target-dependent |

## Rules

- A failed session message must not silently disappear.
- A successful Meta HTTP response means `provider_accepted`, never `sent`,
  `delivered`, or `read`.
- Provider status callbacks are signed delivery evidence only. They are scoped
  to the configured WABA and phone number, correlate by WAMID, and never issue,
  revoke, or invalidate tickets or mutate payment, inventory, scanner, or
  attendee state.
- Unknown WAMIDs and expected WAMIDs from ordinary conversation replies are
  ignored with bounded redacted telemetry; they never create attempts.
- Older or duplicate provider timestamps cannot regress a stronger status.
- A later contradictory success after `failed` is preserved and routes the
  attempt to `manual_review` without an automatic resend.
- If the WhatsApp 24-hour customer-service window is closed, use an approved
  utility template or fallback policy.
- Failed resend must not erase or overwrite earlier successful delivery evidence.
