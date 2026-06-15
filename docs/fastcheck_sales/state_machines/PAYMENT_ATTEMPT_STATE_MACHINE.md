# PaymentAttempt State Machine

## Allowed States

`initialized`, `authorization_url_sent`, `webhook_received`,
`verification_started`, `verified_success`, `verified_amount_mismatch`,
`verified_currency_mismatch`, `failed`, `duplicate`, `manual_review`,
`refunded`.

## Transition Matrix

| From state | To state | Named action | Actor type | Preconditions | Required side effects | Audit required? | Idempotency rule | Terminal? |
|---|---|---|---|---|---|---|---|---|
| `initialized` | `authorization_url_sent` | `send_authorization_url` | `system` | Authorization URL exists and target channel is approved. | Record sent timestamp; redact URL from logs. | yes | Duplicate send follows delivery policy. | no |
| `initialized` | `failed` | `fail_initialization` | `system` | Paystack initialization failed or config invalid. | Store safe failure code/message. | yes | Duplicate failure preserves first failure. | conditional |
| `initialized` | `manual_review` | `review_initialization` | `system/admin` | Initialization result is ambiguous. | Record reason. | yes | Existing review remains. | no |
| `authorization_url_sent` | `webhook_received` | `record_payment_webhook_signal` | `system` | Webhook signature accepted and event stored. | Enqueue verification; do not verify from payload alone. | yes | Duplicate webhook creates duplicate event outcome. | no |
| `authorization_url_sent` | `verification_started` | `start_manual_or_return_verification` | `system` | Provider reference exists. | Call verifier boundary later. | yes | Same reference verification is idempotent. | no |
| `authorization_url_sent` | `failed` | `fail_authorized_attempt` | `system` | Provider failure or local timeout. | Record safe failure reason. | yes | Duplicate failure preserves first reason. | conditional |
| `authorization_url_sent` | `manual_review` | `review_authorized_attempt` | `system/admin` | Provider/local state conflict. | Preserve evidence and reason. | yes | Existing review remains. | no |
| `webhook_received` | `verification_started` | `start_webhook_verification` | `system` | Event is not duplicate and has provider reference. | Start server-side verification. | yes | Same event/reference verifies once. | no |
| `webhook_received` | `duplicate` | `mark_duplicate_webhook_attempt` | `system` | Existing payment attempt/event already processed. | Record duplicate handling. | yes | Duplicate remains terminal. | yes |
| `webhook_received` | `manual_review` | `review_webhook_attempt` | `system/admin` | Event cannot be safely matched. | Record review reason. | yes | Existing review remains. | no |
| `verification_started` | `verified_success` | `mark_verified_success` | `system` | Paystack verification succeeds; amount/currency/reference/event match. | Mark paid; enqueue order transition. | yes | Never downgrade verified success. | no |
| `verification_started` | `verified_amount_mismatch` | `mark_amount_mismatch` | `system` | Verification amount differs from expected. | Move order/payment to review. | yes | Same mismatch is idempotent. | no |
| `verification_started` | `verified_currency_mismatch` | `mark_currency_mismatch` | `system` | Verification currency differs from expected. | Move order/payment to review. | yes | Same mismatch is idempotent. | no |
| `verification_started` | `failed` | `mark_verification_failed` | `system` | Provider says failed or verifier fails safely. | Store safe reason. | yes | Duplicate failure is idempotent. | conditional |
| `verification_started` | `manual_review` | `review_verification` | `system/admin` | Ambiguous provider/local state. | Preserve raw evidence under restricted access. | yes | Existing review remains. | no |
| `verified_success` | `refunded` | `mark_payment_refunded` | `admin/system` | Refund/revocation policy approves. | Trigger ticket revocation if applicable. | yes | Duplicate refund returns refunded. | yes |
| `verified_amount_mismatch` | `manual_review` | `review_amount_mismatch` | `admin/system` | Admin/system review is required. | Record reason and allowed target. | yes | Existing review remains. | no |
| `verified_currency_mismatch` | `manual_review` | `review_currency_mismatch` | `admin/system` | Admin/system review is required. | Record reason and allowed target. | yes | Existing review remains. | no |
| `failed` | `manual_review` | `review_failed_payment_attempt` | `admin/system` | Failure may be recoverable. | Record reason. | yes | Existing review remains. | no |
| `manual_review` | approved target | `resolve_payment_attempt_review` | `admin/system` | Target is explicitly allowed and reason exists. | Run target side effects. | yes | Resolution idempotent by review id. | target-dependent |

## Rules

- Webhook payload alone must never move to `verified_success`.
- Duplicate verification after `verified_success` returns idempotent success.
- Duplicate handling must not downgrade, overwrite, or replace
  `verified_success`.
