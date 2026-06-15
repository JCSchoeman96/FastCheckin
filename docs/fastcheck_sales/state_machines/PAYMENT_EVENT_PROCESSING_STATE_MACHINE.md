# PaymentEvent Processing State Machine

## Allowed States

`stored`, `processing_started`, `processed`, `duplicate`, `unmatched`,
`failed`, `manual_review`.

## Transition Matrix

| From state | To state | Named action | Actor type | Preconditions | Required side effects | Audit required? | Idempotency rule | Terminal? |
|---|---|---|---|---|---|---|---|---|
| `stored` | `processing_started` | `start_payment_event_processing` | `system` | Signature accepted, event not duplicate, worker ready. | Start processing and preserve event id. | yes | Same event processed once. | no |
| `stored` | `duplicate` | `mark_duplicate_payment_event` | `system` | Provider event id or payload hash already exists. | Record duplicate outcome. | yes | Duplicate remains terminal. | yes |
| `stored` | `unmatched` | `mark_unmatched_payment_event` | `system` | Event cannot be matched to local order/payment. | Keep queryable/retryable. | yes | Same unmatched event remains queryable. | no |
| `stored` | `failed` | `fail_payment_event_storage_processing` | `system` | Event cannot be processed safely. | Store safe error. | yes | Failure can be retried safely. | conditional |
| `processing_started` | `processed` | `mark_payment_event_processed` | `system` | Verification and order/payment transitions completed or intentionally skipped. | Record processed_at. | yes | Reprocessing returns processed. | yes |
| `processing_started` | `unmatched` | `mark_processing_unmatched` | `system` | No local reference can be found. | Store reason for support/retry. | yes | Same unmatched state remains. | no |
| `processing_started` | `failed` | `fail_payment_event_processing` | `system` | Provider/local processing error. | Store safe error and retry metadata. | yes | Retry must be safe. | conditional |
| `processing_started` | `duplicate` | `mark_processing_duplicate` | `system` | Another event already handled the same provider reference. | Record duplicate link. | yes | Duplicate remains terminal. | yes |
| `unmatched` | `processing_started` | `retry_unmatched_payment_event` | `system/admin` | Matching data is now available. | Restart bounded processing. | yes | Same retry idempotent by event id. | no |
| `unmatched` | `manual_review` | `review_unmatched_payment_event` | `admin/system` | Retry cannot safely resolve. | Record reason. | yes | Existing review remains. | no |
| `failed` | `processing_started` | `retry_failed_payment_event` | `system/admin` | Retry policy allows. | Restart bounded processing. | yes | Same retry idempotent by event id. | no |
| `failed` | `manual_review` | `review_failed_payment_event` | `admin/system` | Failure requires human/system review. | Record reason. | yes | Existing review remains. | no |
| `manual_review` | approved target | `resolve_payment_event_review` | `admin/system` | Target and reason approved. | Run target side effects. | yes | Resolution idempotent by review id. | target-dependent |

## Rules

- Invalid signatures may be stored for audit but must not trigger payment
  verification.
- Unmatched events must remain queryable and retryable.
- Duplicate events must not mutate verified payment or order state.
- Webhook controllers return quickly after verification, storage, dedupe, and
  enqueue.
