# TicketIssue State Machine

## Allowed States

`pending`, `issued`, `revoked`, `manual_review`.

## Transition Matrix

| From state | To state | Named action | Actor type | Preconditions | Required side effects | Audit required? | Idempotency rule | Terminal? |
|---|---|---|---|---|---|---|---|---|
| `pending` | `issued` | `mark_ticket_issue_issued` | `system` | Verified payment, inventory eligibility, attendee row, unique ticket code, and line sequence exist. | Create/update scanner-compatible attendee visibility; enqueue delivery and event sync. | yes | Duplicate issue returns existing ticket/attendee. | no |
| `pending` | `manual_review` | `review_pending_ticket_issue` | `system/admin` | Issuance precondition failed or ambiguous. | Record reason and preserve partial artifacts. | yes | Existing review remains. | no |
| `issued` | `revoked` | `revoke_issued_ticket` | `admin/system` | Refund/cancel/revocation policy approves and reason exists. | Update scanner visibility, invalidate tokens, enqueue event sync aggregation. | yes | Duplicate revoke returns revoked. | yes |
| `issued` | `manual_review` | `review_issued_ticket` | `admin/system` | Support issue requires review without revocation yet. | Record reason; preserve scanner status unless explicit revoke. | yes | Existing review remains. | no |
| `manual_review` | approved target | `resolve_ticket_issue_review` | `admin/system` | Target and reason approved by policy. | Run target side effects. | yes | Resolution idempotent by review id. | target-dependent |

## Rules

- `TicketIssue.status` represents ticket issuance and validity, not delivery
  attempt history.
- `DeliveryAttempt` is the source of truth for delivery attempts, provider
  responses, fallback, and resend history.
- Revocation must update existing attendee/scanner visibility and enqueue event
  sync aggregation.
