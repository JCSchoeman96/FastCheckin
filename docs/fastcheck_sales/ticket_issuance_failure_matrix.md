# Ticket Issuance Failure Matrix

**Authority:** [VS-09A_ticket_issuance_contract.md](./VS-09A_ticket_issuance_contract.md)  
**Related policy:** [PARTIAL_TICKET_ISSUANCE_POLICY.md](./policies/PARTIAL_TICKET_ISSUANCE_POLICY.md)  
**Last updated:** 2026-06-20

This matrix classifies partial failures **before** VS-09B/VS-09C implement issuing. Every row must have a contract behavior and stable reason code where applicable.

---

## 1. Idempotent success cases

| Failure / condition | Required contract behavior | Order outcome |
|---|---|---|
| Order already `ticket_issued` | Return `{:ok, status: :already_issued}` — do not issue again | Unchanged |
| Duplicate worker after full issuance | Idempotent success; no new Attendee/TicketIssue | Unchanged |
| Attendee unique conflict on **same** `source_reference` with matching data | Treat as existing unit; link/reuse | Continue issuance |
| TicketIssue unique conflict on **same** `(sales_order_line_id, line_item_sequence)` with matching data | Treat as existing unit | Continue issuance |
| Retry after all units exist but order transition failed | Detect complete issuance; finish order transition only | `ticket_issued` |

---

## 2. Partial issuance cases

| Failure | Required contract behavior | Order outcome |
|---|---|---|
| One ticket in multi-ticket order fails recoverably | Do **not** mark full `ticket_issued` | `partially_issued` |
| One ticket fails with non-recoverable conflict | Preserve successful units for retry/audit | `manual_review` |
| Some units completed, some failed with mixed recoverability | Record counts in StateTransition metadata | `partially_issued` or `manual_review` per matrix below |

### Partial vs manual_review decision

| Situation | Outcome |
|---|---|
| Failed units are retry-safe (transient DB, retryable code path) | `partially_issued` |
| Attendee/TicketIssue conflict on **different** order/customer | `manual_review` |
| TicketIssue exists but Attendee link missing and not deterministically recoverable | `manual_review` |
| Unrecoverable invariant violation | `manual_review` |

Aligns with [PARTIAL_TICKET_ISSUANCE_POLICY.md](./policies/PARTIAL_TICKET_ISSUANCE_POLICY.md): partial artifacts preserved; retry links existing rows; customer messaging must not deny verified payment.

---

## 3. Split-row recovery cases

| Failure | Required contract behavior | Owner slice |
|---|---|---|
| Existing Attendee found but TicketIssue missing | Retry links/creates missing TicketIssue for that unit | VS-09C |
| TicketIssue exists but Attendee link missing | `manual_review` unless deterministic attendee recovery | VS-09C / support |
| Attendee created in prior attempt, order still `paid_verified` | Resume from durable rows; do not recreate attendees | VS-09B/C |

---

## 4. Preconditions and payment failures

| Failure | Required contract behavior | Reason code |
|---|---|---|
| Order not `paid_verified` / `fulfillment_queued` | `{:error, {:invalid_order_state, state}}` | — |
| No `verified_success` payment attempt | Stay current or `manual_review` | `issuer_invalid_payment_state` |
| Amount/currency mismatch attempt only | Do not issue | `issuer_invalid_payment_state` |
| Checkout not `paid` and no approved late recovery | Do not issue | `issuer_inventory_not_confirmed` |
| Inventory not confirmed after expiry | Do not issue | `issuer_inventory_not_confirmed` |

Issuer must **not** call Paystack or read webhook payloads.

---

## 5. Conflict cases

| Failure | Required contract behavior | Reason code |
|---|---|---|
| Attendee unique conflict, **different** customer/order data | `manual_review`; do not overwrite | `issuer_attendee_conflict` |
| TicketIssue unique conflict on **unrelated** order/line | `manual_review`; do not overwrite | `issuer_ticket_issue_conflict` |
| Partial Attendee rows without matching TicketIssues after failed transaction | Retry links in VS-09C; if stuck, manual review | `issuer_partial_attendee_created` |
| Partial TicketIssue rows without Attendee links | Manual review unless deterministic recovery | `issuer_partial_ticket_issue_created` |

---

## 6. Infrastructure failures

| Failure | Required contract behavior | Reason code |
|---|---|---|
| Order transition fails after all units exist | Retry completes transition without new tickets | `issuer_state_transition_failed` (retry) |
| Event sync enqueue fails after commit | Tickets durable; retry enqueue job (VS-10) | `issuer_event_sync_enqueue_failed` |
| Process crash mid-transaction | Transaction rollback; clean retry | — (transient) |
| Transient DB/Oban failure | `{:error, {:retryable, reason}}` | varies |

---

## 7. Stable manual_review reason codes

All `manual_review` outcomes from issuance must use stable string reason codes:

| Code | When |
|---|---|
| `issuer_attendee_conflict` | Attendee unique conflict on different customer/order |
| `issuer_ticket_issue_conflict` | TicketIssue conflict on unrelated order |
| `issuer_partial_attendee_created` | Attendees exist without completable TicketIssue linkage |
| `issuer_partial_ticket_issue_created` | TicketIssues exist without valid Attendee |
| `issuer_state_transition_failed` | Units complete but order transition cannot finish (non-retryable) |
| `issuer_event_sync_enqueue_failed` | Post-commit sync enqueue failed persistently |
| `issuer_unrecoverable_invariant_violation` | Data invariant broken beyond safe retry |
| `issuer_inventory_not_confirmed` | Checkout/inventory state not approved for issuance |
| `issuer_invalid_payment_state` | Payment preconditions fail at issue time |

Support metadata must aid debugging **without** raw PII or provider payloads.

---

## 8. Customer-visible rules

- After verified payment exists, customer messaging may say fulfillment is pending or under review.
- Must **not** say payment was not received when `verified_success` exists.
- Delivery tokens/QR plaintext must not appear in errors or logs.

---

## 9. Deferred to later slices

| Risk | Control owner |
|---|---|
| Payment reversed after issuance | VS-15A/VS-15B revocation/refund |
| Scanner accepts ticket without Sales audit | VS-09C linking before delivery (VS-11+) |
| Operator manual review resolution UI | VS-12 |
