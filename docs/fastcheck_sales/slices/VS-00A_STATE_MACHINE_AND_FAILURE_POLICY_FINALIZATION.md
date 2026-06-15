# VS-00A State Machine and Failure Policy Finalization

## Purpose

Define accepted state-machine and failure-policy contracts before Ash resources,
actions, workers, payment handlers, checkout flows, or ticket issuance logic are
implemented.

## Scope

In scope:

- Legal transition matrices for Sales stateful resources.
- Terminal states and recovery rules.
- Named action requirements.
- Actor and precondition expectations.
- Required side effects for later implementation.
- `StateTransition` audit requirements.
- Payment-after-expiry, partial issuance, manual review, and terminal-state
  policies.

Out of scope:

- Runtime implementation.
- Ash resources.
- Migrations.
- Redis scripts.
- Paystack or Meta/WhatsApp clients.
- Oban workers.
- LiveView/admin UI.
- Tests.
- Android scanner or mobile API changes.

## Required Matrix Format

Each state-machine document uses this table shape:

| From state | To state | Named action | Actor type | Preconditions | Required side effects | Audit required? | Idempotency rule | Terminal? |
|---|---|---|---|---|---|---|---|---|

Generic `update_status` and `update_state` actions are forbidden.

## StateTransition Audit Contract

Every status/state transition requires `StateTransition` audit. Manual
admin/operator transitions require a non-empty reason. System transitions should
preserve `correlation_id`, `request_id`, or `idempotency_key` when available.

## Documents

- [State Machine Master](../state_machines/STATE_MACHINE_MASTER.md)
- [Order State Machine](../state_machines/ORDER_STATE_MACHINE.md)
- [Checkout Session State Machine](../state_machines/CHECKOUT_SESSION_STATE_MACHINE.md)
- [Payment Attempt State Machine](../state_machines/PAYMENT_ATTEMPT_STATE_MACHINE.md)
- [Payment Event Processing State Machine](../state_machines/PAYMENT_EVENT_PROCESSING_STATE_MACHINE.md)
- [Ticket Issue State Machine](../state_machines/TICKET_ISSUE_STATE_MACHINE.md)
- [Delivery Attempt State Machine](../state_machines/DELIVERY_ATTEMPT_STATE_MACHINE.md)
- [Conversation State Machine](../state_machines/CONVERSATION_STATE_MACHINE.md)
- [Payment After Expiry Policy](../policies/PAYMENT_AFTER_EXPIRY_POLICY.md)
- [Partial Ticket Issuance Policy](../policies/PARTIAL_TICKET_ISSUANCE_POLICY.md)
- [Manual Review Policy](../policies/MANUAL_REVIEW_POLICY.md)
- [Terminal State Policy](../policies/TERMINAL_STATE_POLICY.md)

## Completion Checklist

- [x] Define Order, CheckoutSession, PaymentAttempt, PaymentEvent, TicketIssue,
  DeliveryAttempt, and Conversation state machines.
- [x] Use the required transition matrix format.
- [x] Forbid generic `update_status` and `update_state`.
- [x] Require `StateTransition` audit for state changes.
- [x] Define payment-after-expiry, partial issuance, manual review, and
  terminal-state policies.

## RED Documentation Checks

VS-00A is not accepted if:

- Any required state-machine document is missing.
- A state machine permits generic status mutation.
- Payment webhook payload alone can mark payment verified.
- Terminal-state recovery is implicit or unaudited.
- Manual review has generic unrestricted exits.
- Ticket issuance can occur before verified payment.
- Duplicate workers can create duplicate tickets.
- Customer messaging can deny payment after durable verified payment exists.

## GREEN Documentation Checks

VS-00A is accepted when:

- Every state machine uses named actions and explicit preconditions.
- Every state transition requires `StateTransition` audit.
- Dangerous transitions list side effects and idempotency rules.
- Payment-after-expiry and partial issuance policies are explicit.
- Manual review and terminal-state recovery are constrained.
- No runtime code is added.

## Acceptance Criteria

- The state-machine and policy documents exist in allowed docs paths.
- State transitions are explicit, named, and auditable.
- Failure policies prevent unsafe payment, inventory, issuance, and recovery
  shortcuts.
- Later implementation slices can convert these contracts into allow/deny tests.
