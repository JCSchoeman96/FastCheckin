# P0-C Automatic Complete Ticket Delivery

## Goal

Automatically deliver every issued ticket unit for a WhatsApp order through a
durable handoff. PostgreSQL delivery intents and attempts, rather than Redis or
Oban job uniqueness, are the correctness authority.

## Runtime law

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

Ticket issuance and the coordinator job insert share one Postgres transaction
for a WhatsApp order. If the insert fails, the transition and newly created
TicketIssues roll back. An idempotent issuer replay repairs the handoff.

The coordinator validates the Order's exact `sales_conversation_id`, phone
match, order status, and complete safe TicketIssue set. It uses bounded keyset
pagination and commits each intent page and its outbound jobs together. Each
worker receives only its durable ID. The customer does not need to send another
message to start delivery.

## Durable delivery model

`TicketDeliveryIntent` is one logical customer delivery identity. The
`initial_ticket_delivery` identity is unique per TicketIssue. A verified resend
identity is unique per resend challenge and remains subject to the existing
identity, OTP, ownership, and replay checks.

`DeliveryAttempt` remains the audit row for one transport/provider attempt. Safe
local retries create increasing attempt numbers beneath the same intent.
Provider acceptance, sent/delivered/read callbacks, and provider failure
evidence stay on attempts; the intent stores the automatic-send lifecycle.

Redis dedupe is an optimization only. Database uniqueness, row locking, and
attempt evidence govern correctness across duplicate and horizontal worker
execution. Automatic delivery currently targets WhatsApp source orders only.
This pack does not add email or wallet delivery.

## Conversation authority

WhatsApp checkout accepts an explicit `sales_conversation_id`, verifies that
the exact Conversation exists and its `phone_e164` matches `buyer_phone` before
inventory reservation, and persists that FK on the Order. Checkout replay must
retain the same binding. Delivery never searches for a Conversation by phone,
wa_id, or JSON state. A historical WhatsApp Order with no binding fails closed
into audited manual review.

## Failure and crash behavior

- Each safe retryable local transport error creates one failed DeliveryAttempt
  and reuses the queued intent with the next `attempt_number`.
- Retry exhaustion, permanent failure, unsafe ownership, and ambiguous provider
  outcomes enter manual review with safe fixed classifications.
- A process loss after an outbound call with no durable acceptance is
  ambiguous and never causes an automatic duplicate customer message.
- A durable provider-accepted attempt repairs a queued intent on retry without
  another provider call.
- Verified resend challenges remain verified and unconsumed until acceptance
  is durable; lost-response recovery uses the accepted attempt evidence.
- Failed delivery does not modify payment, inventory, ticket validity, or
  scanner state.

## Scope

This pack adds the logical intent resource, its narrow migration and partial
unique identities, the order coordinator and worker, transactional issuance
handoff, the intent-authoritative send worker, exact WhatsApp checkout
conversation binding, and the verified resend handoff. It does not implement
revocation batching, payment reconciliation, conversation restart/idempotency
redesign, refunds, Apple Wallet, or Google Wallet.

## Verification

See the focused suites and quality gates recorded in the pull request. Required
coverage includes four-ticket application-created end-to-end delivery,
duplicates of all downstream workers, greater-than-50 keyset pagination,
conversation binding failures, issuer handoff rollback, resend protections,
safe retries, ambiguous outcomes, and provider-acceptance crash recovery.
