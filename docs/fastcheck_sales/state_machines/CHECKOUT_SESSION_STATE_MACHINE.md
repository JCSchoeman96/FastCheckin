# CheckoutSession State Machine

## Allowed States

`created`, `hold_attached`, `payment_link_sent`, `payment_started`, `paid`,
`expired`, `released`, `failed`, `manual_review`.

## Transition Matrix

| From state | To state | Named action | Actor type | Preconditions | Required side effects | Audit required? | Idempotency rule | Terminal? |
|---|---|---|---|---|---|---|---|---|
| `created` | `hold_attached` | `attach_inventory_hold` | `system` | `ReservationLedger.reserve` succeeds. | Store hold key/token/expires_at. | yes | Same idempotency key returns existing hold. | no |
| `created` | `failed` | `fail_checkout_creation` | `system` | Hold or validation cannot be created. | Store machine-readable reason. | yes | Same failure reason remains. | conditional |
| `created` | `expired` | `expire_created_session` | `system` | Session expires before hold. | Mark expired_at. | yes | Existing expired state unchanged. | yes |
| `hold_attached` | `payment_link_sent` | `send_payment_link` | `system` | Paystack authorization URL exists and is safe to send. | Record sent timestamp; do not log URL. | yes | Re-sending uses delivery policy. | no |
| `hold_attached` | `released` | `release_held_session` | `system/admin` | No verified payment and hold is unconsumed. | `ReservationLedger.release`. | yes | Duplicate release does not double-increment. | yes |
| `hold_attached` | `expired` | `expire_held_session` | `system` | Hold expiry reached; no verified payment. | Release unconsumed hold. | yes | Expiry is idempotent. | yes |
| `hold_attached` | `failed` | `fail_held_session` | `system` | Provider or local setup fails before payment. | Release hold if safe. | yes | Duplicate fail preserves first reason. | conditional |
| `payment_link_sent` | `payment_started` | `mark_payment_started` | `system/customer_session` | Customer opens/starts provider flow. | Record payment started signal. | yes | Duplicate start is no-op. | no |
| `payment_link_sent` | `released` | `release_sent_session` | `system/admin` | No verified payment and release reason exists. | Release unconsumed hold. | yes | Duplicate release is no-op. | yes |
| `payment_link_sent` | `expired` | `expire_sent_session` | `system` | Hold/session expiry reached. | Release unconsumed hold. | yes | Duplicate expiry is no-op. | yes |
| `payment_link_sent` | `failed` | `fail_sent_session` | `system` | Provider link cannot be used safely. | Record reason; release hold if safe. | yes | Same failure is idempotent. | conditional |
| `payment_started` | `paid` | `mark_session_paid` | `system` | Verified payment handling succeeds. | Mark paid; prevent hold release. | yes | Duplicate verified payment returns paid. | yes |
| `payment_started` | `expired` | `expire_started_session` | `system` | Hold expired and no verified payment exists. | Release hold; preserve payment attempt history. | yes | Duplicate expiry is no-op. | yes |
| `payment_started` | `manual_review` | `flag_started_session_review` | `system/admin` | Payment or inventory state ambiguous. | Preserve evidence and reason. | yes | Existing review remains. | no |
| `expired` | `manual_review` | `recover_expired_paid_session` | `system/admin` | Verified late payment exists. | Apply payment-after-expiry policy. | yes | Same verified payment review is idempotent. | no |
| `failed` | `manual_review` | `review_failed_session` | `admin/system` | Failure may be recoverable. | Record recovery reason. | yes | Existing review remains. | no |
| `manual_review` | approved target | `resolve_session_review_to_target` | `admin/system` | Target and reason approved by policy. | Run target side effects. | yes | Resolution idempotent by review id. | target-dependent |

## Rules

- `paid`, `released`, and `expired` are terminal unless explicit recovery exists.
- Released and expired sessions must never release already-consumed holds.
- `CheckoutSession` is never atomic inventory authority.
- Token-bearing payment links must not be logged.
