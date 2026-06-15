# Order State Machine

## Allowed States

`draft`, `awaiting_payment`, `payment_pending`, `paid_unverified`,
`paid_verified`, `fulfillment_queued`, `ticket_issued`, `partially_issued`,
`manual_review`, `cancelled`, `expired`, `refunded`.

## Transition Matrix

| From state | To state | Named action | Actor type | Preconditions | Required side effects | Audit required? | Idempotency rule | Terminal? |
|---|---|---|---|---|---|---|---|---|
| `draft` | `awaiting_payment` | `open_checkout` | `system` | Order has event_id, lines, source_channel, public_reference. | Create/attach checkout intent. | yes | Same public_reference returns existing open order. | no |
| `draft` | `cancelled` | `cancel_draft_order` | `system/admin` | No verified payment and no issued tickets. | Release active hold if present. | yes | Repeated cancel returns cancelled. | yes |
| `draft` | `expired` | `expire_draft_order` | `system` | Order expired before payment start. | Release active hold if present. | yes | Repeated expiry returns expired. | yes |
| `awaiting_payment` | `payment_pending` | `mark_payment_pending` | `system` | Paystack initialization exists or customer was sent payment URL. | Record pending payment metadata. | yes | Same payment reference is idempotent. | no |
| `awaiting_payment` | `paid_unverified` | `record_unverified_payment_signal` | `system` | Webhook or return signal exists; verification not complete. | Persist signal; enqueue verification. | yes | Duplicate signal does not create duplicate attempt. | no |
| `awaiting_payment` | `paid_verified` | `mark_paid_verified` | `system` | Server-side verification succeeds with amount, currency, reference, and event match. | Record paid_at; prepare inventory consume. | yes | Existing verified payment is not downgraded. | no |
| `awaiting_payment` | `expired` | `expire_awaiting_payment_order` | `system` | Checkout hold expired and no verified payment exists. | Release unconsumed hold. | yes | Repeated expiry returns expired. | yes |
| `awaiting_payment` | `cancelled` | `cancel_awaiting_payment_order` | `admin/system` | No verified payment and no issued tickets. | Release active hold and record reason. | yes | Repeated cancel returns cancelled. | yes |
| `payment_pending` | `paid_unverified` | `record_payment_webhook` | `system` | Webhook stored and signature accepted. | Enqueue server-side verification. | yes | Duplicate webhook remains idempotent. | no |
| `payment_pending` | `paid_verified` | `mark_pending_payment_verified` | `system` | Server-side verification succeeds. | Record paid_at and verification metadata. | yes | Duplicate verification returns verified. | no |
| `payment_pending` | `manual_review` | `flag_pending_payment_review` | `system/admin` | Provider or local state is inconsistent. | Record reason and customer-safe message status. | yes | Same reason does not create duplicate review loops. | no |
| `payment_pending` | `expired` | `expire_pending_payment_order` | `system` | Hold expired and no verified durable payment exists. | Release hold and preserve payment attempt history. | yes | Existing expired state unchanged. | yes |
| `payment_pending` | `cancelled` | `cancel_pending_payment_order` | `admin/system` | No verified durable payment exists. | Release hold and audit reason. | yes | Existing cancelled state unchanged. | yes |
| `paid_unverified` | `paid_verified` | `verify_unverified_payment` | `system` | Server-side verification succeeds with exact checks. | Record paid_at; enqueue inventory consume. | yes | Existing verified state unchanged. | no |
| `paid_unverified` | `manual_review` | `flag_unverified_payment_review` | `system` | Verification mismatch, provider ambiguity, or missing local ownership. | Record review reason. | yes | Same mismatch is idempotent. | no |
| `paid_verified` | `fulfillment_queued` | `queue_fulfillment` | `system` | Inventory consume/re-reserve policy satisfied. | Enqueue issuer worker. | yes | Existing enqueue is idempotent. | no |
| `paid_verified` | `manual_review` | `flag_verified_payment_review` | `system/admin` | Inventory or issuance precondition cannot be safely met. | Preserve verified payment evidence. | yes | Duplicate review preserves original evidence. | no |
| `paid_verified` | `refunded` | `mark_verified_order_refunded` | `admin/system` | Refund/revocation policy approves and audit reason exists. | Revoke related tickets if issued; update scanner visibility where needed. | yes | Duplicate refund action returns refunded. | yes |
| `fulfillment_queued` | `ticket_issued` | `mark_ticket_issued` | `system` | All attendee and TicketIssue rows created idempotently. | Enqueue event sync aggregation and delivery. | yes | Duplicate issuer returns existing tickets. | yes |
| `fulfillment_queued` | `partially_issued` | `mark_partially_issued` | `system` | Some, but not all, ticket rows or attendee rows exist. | Record partial failure metadata; enqueue retry/review. | yes | Retry links existing rows. | no |
| `fulfillment_queued` | `manual_review` | `flag_fulfillment_review` | `system/admin` | Issuance cannot safely continue automatically. | Record reason and preserve partial artifacts. | yes | Existing review remains. | no |
| `partially_issued` | `ticket_issued` | `complete_partial_issuance` | `system` | Missing ticket artifacts are safely completed. | Enqueue delivery and event sync aggregation. | yes | Existing issued rows reused. | yes |
| `partially_issued` | `manual_review` | `flag_partial_issuance_review` | `system/admin` | Retry cannot safely complete. | Preserve partial artifacts and reason. | yes | Existing review remains. | no |
| `partially_issued` | `refunded` | `refund_partially_issued_order` | `admin/system` | Refund/revocation policy approves. | Revoke issued artifacts and update scanner visibility. | yes | Duplicate refund returns refunded. | yes |
| `ticket_issued` | `refunded` | `refund_issued_order` | `admin/system` | Refund/revocation policy approves and audit reason exists. | Revoke tickets, invalidate tokens, enqueue scanner sync. | yes | Duplicate refund returns refunded. | yes |
| `ticket_issued` | `manual_review` | `flag_issued_order_review` | `admin/system` | Support issue requires review without invalidating issued ticket yet. | Record reason; do not mutate scanner validity unless explicit revocation. | yes | Duplicate review preserves issued evidence. | no |
| `manual_review` | approved target | `resolve_manual_review_to_target` | `admin/system` | Target is explicitly allowed by policy and reason exists. | Record recovery metadata and target side effects. | yes | Same resolution idempotent by review id. | target-dependent |

## Forbidden Transitions

- Any transition from `refunded`, `cancelled`, or `expired` without explicit
  admin/system recovery policy.
- `paid_unverified` to `fulfillment_queued`.
- `payment_pending` to `ticket_issued`.
- Any transition that issues tickets without verified payment.

## Customer-Facing Rule

Once verified payment exists, no customer channel may state that payment was not
received. The customer may be told that fulfillment is pending, under review, or
awaiting support.
