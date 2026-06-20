# Partial Ticket Issuance Policy

## Purpose

Define retry-safe behavior when multi-ticket issuance partially succeeds.

**Authoritative expansion:** [VS-09A failure matrix](../ticket_issuance_failure_matrix.md) and
[VS-09A issuance contract](../VS-09A_ticket_issuance_contract.md). This policy remains the
high-level summary; stable `issuer_*` reason codes live in the failure matrix.

## Policy

| Case | Outcome |
|---|---|
| All tickets issued successfully | Order can move to `ticket_issued`. |
| Some attendee rows created but `TicketIssue` insert fails | Retry links existing attendee rows and completes `TicketIssue` rows. |
| `TicketIssue` rows exist but order transition fails | Retry detects existing issues and completes order transition. |
| One ticket in a multi-ticket order fails | Order moves to `partially_issued` or `manual_review` according to the matrix. |
| Duplicate issuer worker execution | Must not create duplicate attendees or tickets. |
| Order already `ticket_issued` | Retry returns idempotent success. |

## Required Idempotency Anchors

- Order public reference.
- Order line id.
- `line_item_sequence`.
- Payment provider reference.
- Issuer worker idempotency key.
- Existing attendee/ticket identifiers.

## Rules

- Partial artifacts must be preserved for retry and audit.
- Retry must prefer linking existing rows over creating replacements.
- A failed ticket in a multi-ticket order must not erase successfully issued
  tickets.
- Customer-facing messaging may say fulfillment is pending or under review, but
  must not say payment was not received after verified payment exists.

## Future Tests

- Duplicate issuer workers do not duplicate attendees.
- Missing `TicketIssue` rows are completed against existing attendees.
- Existing issued tickets are not regenerated during retry.
- Partial failure moves to `partially_issued` or `manual_review` with audit.
