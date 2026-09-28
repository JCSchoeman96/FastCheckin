# TicketDeliveryIntent State Machine

## Purpose

`TicketDeliveryIntent` is the durable identity of one requested customer ticket
delivery. It is not a provider attempt. `DeliveryAttempt` remains the audit row
for each individual transport attempt, and an intent can have multiple
attempts after safe local retries.

The two purposes are:

- `initial_ticket_delivery`: one intent per TicketIssue, created by the
  automatic order coordinator, with no resend challenge.
- `verified_ticket_resend`: one intent per verified resend challenge, linked to
  that exact challenge.

## Allowed States

`queued`, `provider_accepted`, `fallback_required`, `manual_review`,
`cancelled`.

Automatic sending ends when an intent reaches `provider_accepted`,
`fallback_required`, `manual_review`, or `cancelled`. Provider `sent`,
`delivered`, `read`, and later callback evidence stays on `DeliveryAttempt`.

## Transition Matrix

| From state | To state | Cause | Required behavior |
|---|---|---|---|
| new | `queued` | Coordinator or verified resend handoff | Create or reuse the database-unique logical identity and insert the send job in the same transaction. |
| `queued` | `provider_accepted` | Provider acceptance is durably recorded | Accept the linked DeliveryAttempt and intent atomically; for resend, consume the verified challenge exactly once after acceptance is durable. |
| `queued` | `fallback_required` | Existing delivery policy requires fallback | Mark the intent and corresponding DeliveryAttempt; do not automatically send through an unapproved channel. |
| `queued` | `manual_review` | Ambiguous result, permanent failure, retry exhaustion, relationship mismatch, or unsafe commercial state | Preserve attempt evidence and require operational action; never blindly resend an ambiguous attempt. |
| `queued` | `cancelled` | Ticket or Order becomes unsafe to deliver | Stop automatic sending without revoking or changing scanner state. |
| `manual_review` | `provider_accepted` | Durable accepted attempt is found during crash recovery | Reconcile the intent from database evidence; do not call the provider again. |

## Database Identities

- Initial delivery: unique `(ticket_issue_id, purpose)` where purpose is
  `initial_ticket_delivery`.
- Verified resend: unique `ticket_resend_challenge_id`.
- Each intent's attempts: unique `(ticket_delivery_intent_id, attempt_number)`.
- Commercial and audit foreign keys use delete restriction.

These PostgreSQL identities are the correctness authority. Oban uniqueness
and Redis dedupe can reduce duplicate work but do not establish delivery
correctness.

## Runtime Law

```text
fulfillment_queued
    ↓
all ticket units issued
    ↓
ticket_issued
    ↓
TicketDeliveryCoordinatorWorker durably queued
    ↓
one TicketDeliveryIntent per issued unit
    ↓
one or more DeliveryAttempts per intent as transport retries require
```

Issuance and coordinator-job insertion commit together for WhatsApp orders. The
coordinator checks the exact Order-bound conversation and validates the entire
issued-unit set before sending work. It uses bounded keyset pagination and
commits each intent page together with its outbound jobs. Automatic delivery
currently targets WhatsApp source orders; no email or wallet delivery is
implied.

## Failure and Recovery Rules

- A safe retryable local transport error marks its DeliveryAttempt `failed`,
  leaves the intent `queued`, and lets Oban retry with the next attempt number.
- When safe transport retries are exhausted, both the attempt and intent enter
  review with the fixed reason `safe_transport_retries_exhausted`.
- An unresolved `dispatching` attempt or any outcome that may have reached the
  provider but lacks durable acceptance becomes `manual_review`; no automatic
  resend occurs.
- If an accepted DeliveryAttempt exists while the intent is still `queued`, a
  retry repairs the intent to `provider_accepted` without another provider call.
- Historical WhatsApp Orders without `sales_conversation_id` enter operational
  review. Conversation lookup by phone, wa_id, or JSON state is not a fallback.
- Delivery failure does not change payment status, restore inventory, revoke
  tickets, or mutate scanner state.
