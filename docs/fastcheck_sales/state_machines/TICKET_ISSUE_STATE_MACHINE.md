# TicketIssue State Machine

## Allowed States

`pending`, `issued`, `revoked`, `manual_review`.

## Transition Matrix

| From state | To state | Named action | Actor type | Preconditions | Required side effects | Audit required? | Idempotency rule | Terminal? |
|---|---|---|---|---|---|---|---|---|
| `pending` | `issued` | `mark_ticket_issue_issued` | `system` | Verified payment, inventory eligibility, attendee row, unique ticket code, and line sequence exist. | Create/update scanner-compatible attendee visibility; enqueue delivery and event sync. | yes | Duplicate issue returns existing ticket/attendee. | no |
| `pending` | `manual_review` | `review_pending_ticket_issue` | `system/admin` | Issuance precondition failed or ambiguous. | Record reason and preserve partial artifacts. | yes | Existing review remains. | no |
| `issued` | `revoked` | `revoke_issued_ticket` | `admin/system` | Revocation policy approves and reason exists. For Order-level revocation, the Order is locked and reloaded before paging all issued TicketIssues. | Update scanner visibility, invalidate tokens, and aggregate mobile sync invalidations. | yes | Duplicate revoke returns revoked; order-level retries process only remaining issued rows. | yes |
| `issued` | `manual_review` | `review_issued_ticket` | `admin/system` | Support issue requires review without revocation yet. | Record reason; preserve scanner status unless explicit revoke. | yes | Existing review remains. | no |
| `manual_review` | approved target | `resolve_ticket_issue_review` | `admin/system` | Target and reason approved by policy. | Run target side effects. | yes | Resolution idempotent by review id. | target-dependent |

## Rules

- `TicketIssue.status` represents ticket issuance and validity, not delivery
  attempt history.
- `DeliveryAttempt` is the source of truth for delivery attempts, provider
  responses, fallback, and resend history.
- Revocation must update existing attendee/scanner visibility and aggregate
  event sync invalidations.
- Order-level revocation pages all `issued` rows with stable ascending-id
  keyset pagination. Its page size is an implementation/performance detail;
  completeness is an authoritative final count of zero issued rows.
- The platform customer purchase ceiling does not limit revocation of
  historical Orders of any size.
