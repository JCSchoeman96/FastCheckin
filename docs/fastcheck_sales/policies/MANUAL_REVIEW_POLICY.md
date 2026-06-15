# Manual Review Policy

## Purpose

Define manual review as an explicit recovery state, not a loophole for generic
status mutation.

## Who May Enter Manual Review

| Actor | Allowed when |
|---|---|
| `system` | Provider/local state is ambiguous, unsafe, mismatched, or retry-exhausted. |
| `admin` | Event-scoped admin needs support/recovery handling. |
| `operator` | Only when a later policy grants a narrow event-scoped handoff action. |
| `customer_session` | Never directly; customer actions may trigger system handoff. |

## Who May Exit Manual Review

Only `admin` or `system` actors may exit manual review, and only to an approved
target state listed in the relevant state-machine document.

## Required Metadata

- Review reason.
- Actor type and actor id where available.
- Event id.
- Resource id/public reference.
- Target state.
- Correlation id or request id where available.
- Idempotency key where available.

## Rules

- Manual review transitions require explicit target states.
- Admin/operator manual actions require `StateTransition` reason.
- Manual review must not bypass Redis inventory, Paystack verification,
  idempotent ticket issuance, `DeliveryAttempt` audit, or scanner-safe
  revocation.
- Customer messages must be safe and truthful.

## Future Tests

- Manual review exit without reason is denied.
- Manual review exit to unapproved target is denied.
- Operator cannot perform admin-only recovery.
- Cross-event manual action is denied.
