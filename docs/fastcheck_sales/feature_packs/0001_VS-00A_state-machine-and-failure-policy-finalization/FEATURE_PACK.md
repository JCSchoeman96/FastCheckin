# FastCheck Sales Feature Planning Pack — VS-00A State Machine and Failure Policy Finalization

**Pack ID:** `0001_VS-00A_state-machine-and-failure-policy-finalization`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0001_VS-00A_state-machine-and-failure-policy-finalization/`  
**Slice:** `VS-00A`  
**Slice name:** State Machine and Failure Policy Finalization  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Ready for planning after VS-00  
**Primary area:** Docs / Architecture / QA  
**Depends on:** VS-00  
**Blocks:** VS-00C, VS-01A+, VS-05, VS-07A–VS-07C, VS-09A–VS-09D, VS-13, VS-15A–VS-15B, VS-18–VS-19  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack defines the legal state transitions and failure policies for the FastCheck Sales platform before any Ash resources, actions, workers, payment handlers, checkout flows, or ticket issuance logic are implemented.

This is a planning and contract slice only. It must produce documentation clear enough that later coding agents cannot invent unsafe transitions.

Core product framing to preserve:

```text
FastCheck Sales is multi-channel, but WhatsApp is first.

Primary production customer channel:
  WhatsApp via Meta Cloud API

Secondary supported Sales paths:
  admin-assisted sales
  web checkout sales
  internal pilot sales

All channels must use the same Sales core:
  Redis inventory reservation
  Paystack server-side verification
  idempotent ticket issuance
  DeliveryAttempt audit
  scanner-safe revocation
```

---

## 2. Ultimate Outcome

After VS-00A is complete, the project has accepted state-machine contracts for:

```text
Order
CheckoutSession
PaymentAttempt
PaymentEvent
TicketIssue
DeliveryAttempt
Conversation
```

It also has accepted failure-policy contracts for:

```text
payment after checkout/hold expiry
partial ticket issuance
manual review recovery
terminal states
late and duplicate webhooks
late verified payment
duplicate workers
admin override boundaries
customer-facing message consistency
```

No implementation code should be written in this slice.

---

## 3. Scope

### In scope

```text
Create legal transition matrices.
Define terminal states and recovery rules.
Define action names tied to allowed transitions.
Define actor permissions at transition-contract level.
Define required preconditions for dangerous transitions.
Define side effects that later slices must implement.
Define payment-after-expiry policy.
Define partial ticket issuance policy.
Define manual-review policy.
Define customer-message consistency rules.
Define RED/GREEN documentation validation tests.
```

### Out of scope

```text
No Elixir implementation code.
No Ash resource modules.
No migrations.
No Ash actions implemented.
No Redis Lua scripts.
No Paystack client or webhook implementation.
No Meta API implementation.
No Oban workers.
No LiveView/admin UI.
No scanner changes.
No Ecto Attendee changes.
```

---

## 4. Domain and Ash Details

### Ash domain

```text
FastCheck.Sales
```

### Ash resources referenced but not implemented

```text
FastCheck.Sales.Order
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.PaymentEvent
FastCheck.Sales.TicketIssue
FastCheck.Sales.DeliveryAttempt
FastCheck.Sales.Conversation
FastCheck.Sales.StateTransition
```

### Ash resources not directly state-machine-focused in this slice

```text
FastCheck.Sales.TicketOffer
FastCheck.Sales.OrderLine
```

These resources are still relevant because Order and TicketIssue transitions depend on offer/order-line constraints, but VS-00A does not define their full resource implementation.

### StateTransition audit contract

Every state-changing transition matrix must state whether a `StateTransition` row is required.

Default rule:

```text
Every status/state transition requires StateTransition audit.
Manual admin/operator transitions require a non-empty reason.
System transitions should preserve correlation_id or idempotency_key when available.
```

### Non-Ash boundaries to preserve

```text
Paystack verification stays outside Ash resources.
Redis inventory mutation stays outside Ash resources.
Meta Cloud API calls stay outside Ash resources.
Ticket issuance orchestration stays in FastCheck.Tickets.Issuer.
Existing Attendee/scanner validity stays in existing Ecto/scanner path.
WhatsApp, web, and admin entrypoints are interface layers only.
```

---

## 5. Required Files / Artifacts

The coding agent should create documentation artifacts only.

Recommended repo paths:

```text
docs/fastcheck_sales/slices/VS-00A_STATE_MACHINE_AND_FAILURE_POLICY_FINALIZATION.md
docs/fastcheck_sales/state_machines/STATE_MACHINE_MASTER.md
docs/fastcheck_sales/state_machines/ORDER_STATE_MACHINE.md
docs/fastcheck_sales/state_machines/CHECKOUT_SESSION_STATE_MACHINE.md
docs/fastcheck_sales/state_machines/PAYMENT_ATTEMPT_STATE_MACHINE.md
docs/fastcheck_sales/state_machines/PAYMENT_EVENT_PROCESSING_STATE_MACHINE.md
docs/fastcheck_sales/state_machines/TICKET_ISSUE_STATE_MACHINE.md
docs/fastcheck_sales/state_machines/DELIVERY_ATTEMPT_STATE_MACHINE.md
docs/fastcheck_sales/state_machines/CONVERSATION_STATE_MACHINE.md
docs/fastcheck_sales/policies/PAYMENT_AFTER_EXPIRY_POLICY.md
docs/fastcheck_sales/policies/PARTIAL_TICKET_ISSUANCE_POLICY.md
docs/fastcheck_sales/policies/MANUAL_REVIEW_POLICY.md
docs/fastcheck_sales/policies/TERMINAL_STATE_POLICY.md
```

If the repo already has a different docs convention, follow the existing convention but keep names explicit and searchable.

---

## 6. Required Matrix Format

Every state-machine document must use this table shape:

| From state | To state | Named action | Actor type | Preconditions | Required side effects | Audit required? | Idempotency rule | Terminal? |
|---|---|---|---|---|---|---|---|---|
| example | example | example_action | system/admin/operator/customer_session | exact condition | exact side effect | yes/no | exact retry rule | yes/no |

Every state-machine document must also include:

```text
allowed states
terminal states
forbidden transitions
manual recovery transitions
duplicate/retry behavior
customer-facing message rule if customer-visible
required StateTransition metadata
```

Generic `update_status` or `update_state` actions are forbidden.

---

## 7. Required State Machines

## 7.1 Order state machine

Required states:

```text
draft
awaiting_payment
payment_pending
paid_unverified
paid_verified
fulfillment_queued
ticket_issued
partially_issued
manual_review
cancelled
expired
refunded
```

Minimum transition constraints:

```text
draft -> awaiting_payment | cancelled | expired
awaiting_payment -> payment_pending | paid_unverified | paid_verified | expired | cancelled
payment_pending -> paid_unverified | paid_verified | manual_review | expired | cancelled
paid_unverified -> paid_verified | manual_review
paid_verified -> fulfillment_queued | manual_review | refunded
fulfillment_queued -> ticket_issued | partially_issued | manual_review
partially_issued -> ticket_issued | manual_review | refunded
ticket_issued -> refunded | manual_review
manual_review -> allowed recovery target only with admin/system reason
cancelled -> terminal unless explicit admin recovery action exists
expired -> terminal unless verified late payment recovery action exists
refunded -> terminal unless explicit admin recovery action exists
```

Dangerous transition preconditions:

```text
mark_paid_verified requires Paystack server-side verification success, amount match, currency match, provider reference match, and order ownership.
queue_fulfillment requires paid_verified and inventory consume/re-reserve policy satisfied.
mark_ticket_issued requires attendee rows, TicketIssue rows, event sync aggregation enqueue, and idempotent issuance result.
ticket_issued -> refunded requires TicketIssue revocation, scanner visibility update, sync aggregation enqueue, token invalidation, and audit reason.
```

Customer-facing rule:

```text
Once any durable verified payment exists, no customer-facing channel may say payment was not received.
```

---

## 7.2 CheckoutSession state machine

Required states:

```text
created
hold_attached
payment_link_sent
payment_started
paid
expired
released
failed
manual_review
```

Minimum transition constraints:

```text
created -> hold_attached | failed | expired
hold_attached -> payment_link_sent | released | expired | failed
payment_link_sent -> payment_started | released | expired | failed
payment_started -> paid | expired | manual_review
paid -> terminal idempotent success
released -> terminal unless explicit recovery action exists
expired -> manual_review only if verified late payment exists
failed -> manual_review or terminal depending reason
manual_review -> explicit admin/system recovery only
```

Rules:

```text
released and expired sessions must not release already-consumed holds.
paid requires verified payment handling and inventory consume/re-reserve policy.
expired with verified late payment must follow payment-after-expiry policy.
CheckoutSession must never be the source of atomic inventory truth.
```

---

## 7.3 PaymentAttempt state machine

Required states:

```text
initialized
authorization_url_sent
webhook_received
verification_started
verified_success
verified_amount_mismatch
verified_currency_mismatch
failed
duplicate
manual_review
refunded
```

Minimum transition constraints:

```text
initialized -> authorization_url_sent | failed | manual_review
authorization_url_sent -> webhook_received | verification_started | failed | manual_review
webhook_received -> verification_started | duplicate | manual_review
verification_started -> verified_success | verified_amount_mismatch | verified_currency_mismatch | failed | manual_review
verified_success -> refunded
verified_amount_mismatch -> manual_review
verified_currency_mismatch -> manual_review
failed -> manual_review or terminal depending reason
duplicate -> terminal idempotent outcome
manual_review -> explicit admin/system recovery only
```

Rules:

```text
Webhook payload alone must never move PaymentAttempt to verified_success.
Only server-side Paystack transaction verification may produce verified_success.
Duplicate webhook/verification after verified_success returns idempotent success and records duplicate handling on PaymentEvent, StateTransition metadata, or worker logs.
Duplicate handling must not downgrade, overwrite, or replace verified_success.
```

---

## 7.4 PaymentEvent processing state machine

Required processing states:

```text
stored
processing_started
processed
duplicate
unmatched
failed
manual_review
```

Minimum processing constraints:

```text
stored -> processing_started | duplicate | unmatched | failed
processing_started -> processed | unmatched | failed | duplicate
unmatched -> processing_started | manual_review
failed -> processing_started | manual_review
duplicate -> terminal idempotent outcome
processed -> terminal idempotent outcome
manual_review -> explicit admin/system recovery only
```

Rules:

```text
Invalid signatures may be stored for audit but must not trigger payment verification.
Unmatched events must remain queryable and retryable.
Duplicate events must not mutate verified payment or order state.
The webhook controller must return quickly after verification, storage, dedupe, and enqueue.
```

---

## 7.5 TicketIssue state machine

Required states:

```text
pending
issued
revoked
manual_review
```

Minimum transition constraints:

```text
pending -> issued | manual_review
issued -> revoked | manual_review
revoked -> terminal unless explicit admin recovery action exists
manual_review -> explicit admin/system recovery only
```

Rules:

```text
TicketIssue.status represents ticket issuance and validity, not delivery-attempt history.
DeliveryAttempt is the source of truth for delivery attempts, provider responses, fallback, and resend history.
TicketIssue may expose a derived delivery summary in admin views, but that summary must not replace DeliveryAttempt audit records.
revoked must update existing Attendee/scanner visibility and enqueue event sync aggregation.
```

---

## 7.6 DeliveryAttempt state machine

Required states:

```text
queued
sent
delivered
failed
fallback_required
cancelled
manual_review
```

Minimum transition constraints:

```text
queued -> sent | failed | fallback_required | cancelled
sent -> delivered | failed | fallback_required
delivered -> terminal success
failed -> fallback_required | manual_review | cancelled
fallback_required -> queued | failed | manual_review
cancelled -> terminal unless explicit resend/retry action exists
manual_review -> explicit admin/system recovery only
```

Rules:

```text
A failed session message must not silently disappear.
If the WhatsApp 24-hour customer-service window is closed, use approved utility template or fallback policy.
DeliveryAttempt is the source of truth for delivery audit.
A failed resend must not erase or overwrite earlier successful delivery evidence.
```

---

## 7.7 Conversation state machine

Required states:

```text
new
selecting_language
main_menu
selecting_event
selecting_ticket_type
collecting_quantity
collecting_buyer_name
collecting_email
confirming_order
awaiting_payment
payment_pending
payment_received
ticket_issued
completed
manual_review
cancelled
expired
```

Minimum transition constraints:

```text
new -> selecting_language | main_menu | expired
selecting_language -> main_menu | expired | manual_review
main_menu -> selecting_event | completed | manual_review | expired
selecting_event -> selecting_ticket_type | main_menu | expired
selecting_ticket_type -> collecting_quantity | main_menu | expired
collecting_quantity -> collecting_buyer_name | main_menu | expired
collecting_buyer_name -> collecting_email | confirming_order | expired
collecting_email -> confirming_order | expired
confirming_order -> awaiting_payment | main_menu | cancelled | expired
awaiting_payment -> payment_pending | payment_received | manual_review | expired
payment_pending -> payment_received | ticket_issued | manual_review
payment_received -> ticket_issued | manual_review
ticket_issued -> completed | manual_review
manual_review -> completed | expired | cancelled with reason
cancelled -> terminal unless explicit restart
expired -> terminal unless start_or_resume creates a new session
completed -> terminal unless explicit resend/support flow
```

Rules:

```text
Afrikaans-first number-only flow remains the default UX direction.
Payment-pending conversation messages must not tell the customer that payment or ticket does not exist when durable payment state exists.
Redis hot state may expire, but Postgres checkpoints must preserve enough state to avoid customer confusion.
Conversation must call Sales/Checkout services; it must not own inventory, payment authority, ticket issuance, or scanner validity.
```

---

## 8. Required Failure Policies

## 8.1 Payment after expiry policy

Required outcomes:

| Case | Outcome |
|---|---|
| Payment verified before hold expiry | Consume Redis hold and issue ticket. |
| Payment verified after hold expiry and inventory is still available | Re-reserve/consume inventory, then issue ticket. |
| Payment verified after hold expiry and inventory is unavailable | Move order and payment attempt to manual_review. Do not issue ticket automatically. |
| Webhook arrives after order expired | Verify payment, record event, then apply expiry policy. |
| Duplicate payment/webhook for already-issued order | Return idempotent success. Do not issue again. |
| Amount/currency/reference mismatch | Move to manual_review. Do not issue ticket. |

Rules:

```text
No customer-facing message may say no payment was received after verified payment exists.
Late verified payment must not blindly issue tickets.
Late verified payment must not oversell inventory.
```

## 8.2 Partial ticket issuance policy

Required outcomes:

| Case | Outcome |
|---|---|
| All tickets issued successfully | Order can move to ticket_issued. |
| Some attendee rows created but TicketIssue insert fails | Retry must link existing attendee rows and complete TicketIssue rows. |
| TicketIssue rows exist but order transition fails | Retry must detect existing issues and complete order transition. |
| One ticket in multi-ticket order fails | Order moves to partially_issued or manual_review according to matrix. |
| Duplicate IssueTicketsWorker execution | Must not create duplicate attendees or tickets. |
| Order already ticket_issued | Retry returns idempotent success. |

## 8.3 Manual review policy

Manual review must define:

```text
who may enter manual_review
who may exit manual_review
allowed recovery targets
required audit reason
required metadata
customer-facing messaging rules
forbidden operator-only actions
admin/system-only recovery actions
```

Rules:

```text
Manual review is not a loophole for generic status updates.
Manual review transitions require explicit target states from the approved matrix.
Admin/operator manual actions require StateTransition reason.
```

## 8.4 Terminal state policy

Terminal states must define whether recovery is allowed.

Default terminal states:

```text
Order: ticket_issued, cancelled, expired, refunded
CheckoutSession: paid, released, expired
PaymentAttempt: duplicate, refunded, selected failed states
PaymentEvent: processed, duplicate
TicketIssue: revoked
DeliveryAttempt: delivered, cancelled
Conversation: completed, cancelled, expired
```

Rules:

```text
Terminal states may only be exited through explicitly documented admin/system recovery actions.
Recovery must preserve audit history and never destroy StateTransition records.
```

---

## 9. RED / GREEN Documentation Tests

These are documentation contract tests. They must fail before VS-00A is complete and pass after the pack is accepted.

### RED checks

VS-00A is not accepted while any of these are true:

```text
No Order transition matrix exists.
No CheckoutSession transition matrix exists.
No PaymentAttempt transition matrix exists.
No PaymentEvent processing matrix exists.
No TicketIssue transition matrix exists.
No DeliveryAttempt transition matrix exists.
No Conversation transition matrix exists.
Any matrix lacks named actions.
Any matrix allows generic update_status or update_state.
Any matrix lacks actor type per transition.
Any matrix lacks preconditions for dangerous transitions.
Any matrix lacks StateTransition audit rules.
No payment-after-expiry policy exists.
No partial issuance policy exists.
No manual review policy exists.
No terminal state policy exists.
TicketIssue owns delivery history instead of DeliveryAttempt.
PaymentAttempt can downgrade verified_success to duplicate.
Order ticket_issued cannot reach refund/revocation path.
Conversation payment_pending can tell customer no payment/ticket exists despite durable payment state.
```

### GREEN checks

VS-00A is accepted only when all of these pass:

```text
All seven required state-machine documents exist.
Every state-machine table includes from_state, to_state, named_action, actor_type, preconditions, side effects, audit requirement, idempotency rule, and terminal marker.
Every state-changing path requires StateTransition audit unless explicitly justified.
Manual admin/operator transitions require non-empty reason.
Payment verified_success requires server-side Paystack verification and amount/currency/reference checks.
Duplicate webhook/worker behavior is idempotent and does not overwrite verified_success.
Payment-after-expiry policy prevents blind ticket issuance and oversell.
Partial issuance policy supports retry and prevents duplicate attendees/tickets.
TicketIssue validity state is separated from DeliveryAttempt delivery audit.
Conversation customer-message rules preserve payment truth.
No implementation code is added.
```

Optional command-style documentation checks:

```bash
grep -R "ORDER_STATE_MACHINE" docs/fastcheck_sales/state_machines
grep -R "Payment after expiry" docs/fastcheck_sales
grep -R "generic update_status" docs/fastcheck_sales
grep -R "verified_success" docs/fastcheck_sales/state_machines
grep -R "DeliveryAttempt is the source of truth" docs/fastcheck_sales
grep -R "StateTransition" docs/fastcheck_sales/state_machines
```

These grep checks are sanity checks only. Human review decides acceptance.

---

## 10. Acceptance Criteria

VS-00A is complete when:

```text
All seven state-machine docs exist.
Payment-after-expiry policy exists.
Partial ticket issuance policy exists.
Manual review policy exists.
Terminal state policy exists.
Every transition has named action, actor type, preconditions, side effects, audit rule, idempotency rule, and terminal marker.
Forbidden transitions are documented.
Manual recovery paths are documented.
Customer-facing message consistency rules are documented.
No matrix lets WhatsApp, web, or admin channels own payment, inventory, ticket issuance, or scanner validity.
No implementation code was added.
```

---

## 11. Coding-Agent TOON Prompt

| Field | Content |
|---|---|
| Task | Create the VS-00A state-machine and failure-policy planning documents for FastCheck Sales. |
| Objective | Define legal state transitions and failure policies before Ash resources, actions, checkout, payment verification, ticket issuance, delivery, admin operations, or WhatsApp flows are implemented. |
| Output | `docs/fastcheck_sales/slices/VS-00A_STATE_MACHINE_AND_FAILURE_POLICY_FINALIZATION.md`, seven state-machine docs under `docs/fastcheck_sales/state_machines/`, and four policy docs under `docs/fastcheck_sales/policies/`. |
| Note | Do not write application code. Do not create Ash resources, migrations, Redis scripts, Paystack clients, Meta API clients, Oban workers, LiveView UI, or scanner changes. Use explicit named actions only; generic `update_status` or `update_state` actions are forbidden. Every state change must require StateTransition audit unless explicitly justified. Preserve the rule that WhatsApp, web, and admin entrypoints are interface layers only and must call the shared Sales core. |

---

## 12. Copy-Paste Prompt for Coding Agent

```text
You are working on FastCheck Sales, an Elixir Phoenix / Ash 3.x planning project.

Implement only the VS-00A State Machine and Failure Policy Finalization slice.

Your job is documentation and planning only. Do not write application code, migrations, Ash resources, Redis scripts, Paystack code, Meta API code, Oban workers, LiveView UI, or scanner changes.

Use these source docs as the current planning baseline:
- docs/fastcheck_sales/docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
- docs/fastcheck_sales/docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md

Create or update:
- docs/fastcheck_sales/slices/VS-00A_STATE_MACHINE_AND_FAILURE_POLICY_FINALIZATION.md
- docs/fastcheck_sales/state_machines/STATE_MACHINE_MASTER.md
- docs/fastcheck_sales/state_machines/ORDER_STATE_MACHINE.md
- docs/fastcheck_sales/state_machines/CHECKOUT_SESSION_STATE_MACHINE.md
- docs/fastcheck_sales/state_machines/PAYMENT_ATTEMPT_STATE_MACHINE.md
- docs/fastcheck_sales/state_machines/PAYMENT_EVENT_PROCESSING_STATE_MACHINE.md
- docs/fastcheck_sales/state_machines/TICKET_ISSUE_STATE_MACHINE.md
- docs/fastcheck_sales/state_machines/DELIVERY_ATTEMPT_STATE_MACHINE.md
- docs/fastcheck_sales/state_machines/CONVERSATION_STATE_MACHINE.md
- docs/fastcheck_sales/policies/PAYMENT_AFTER_EXPIRY_POLICY.md
- docs/fastcheck_sales/policies/PARTIAL_TICKET_ISSUANCE_POLICY.md
- docs/fastcheck_sales/policies/MANUAL_REVIEW_POLICY.md
- docs/fastcheck_sales/policies/TERMINAL_STATE_POLICY.md

Required state-machine table columns:
- From state
- To state
- Named action
- Actor type
- Preconditions
- Required side effects
- Audit required?
- Idempotency rule
- Terminal?

Required resources/state machines:
- Order
- CheckoutSession
- PaymentAttempt
- PaymentEvent processing
- TicketIssue
- DeliveryAttempt
- Conversation

Required rules:
- Generic update_status/update_state actions are forbidden.
- Every state change requires StateTransition audit unless explicitly justified.
- Manual admin/operator transitions require a non-empty audit reason.
- Paystack webhook alone is not payment authority.
- PaymentAttempt verified_success requires server-side Paystack verification and amount/currency/reference checks.
- Duplicate webhook/verification must not downgrade verified_success to duplicate.
- Payment after expiry must not blindly issue tickets or oversell.
- Ticket issuance retry must not create duplicate attendees or TicketIssue rows.
- TicketIssue.status represents issuance/validity, not delivery history.
- DeliveryAttempt is the source of truth for delivery audit.
- Conversation payment_pending messages must not contradict durable payment state.
- WhatsApp, web checkout, and admin-assisted sales are interface layers only and must call the shared Sales core.

Acceptance criteria:
- All required docs exist.
- Every matrix includes named actions, actors, preconditions, side effects, audit, idempotency, and terminal markers.
- Payment-after-expiry, partial issuance, manual review, and terminal-state policies exist.
- Forbidden transitions are documented.
- No implementation code is added.
```

---

## 13. Human Review Checklist

Before marking VS-00A done, confirm:

```text
No matrix allows a generic status update.
No matrix lets a webhook alone verify payment.
No matrix lets WhatsApp issue tickets.
No matrix lets web/admin checkout bypass inventory/payment rules.
No matrix lets verified_success become duplicate.
No matrix treats TicketIssue as the source of delivery audit.
Every dangerous transition has preconditions.
Every manual recovery has an audit reason.
Payment-after-expiry is explicit.
Partial issuance retry behavior is explicit.
Terminal state recovery behavior is explicit.
Customer-facing payment-pending messaging is truthful.
No implementation code was added.
```

---

## 14. Success Definition

VS-00A succeeds when future coding agents cannot reasonably invent unsafe behavior for:

```text
payment after expiry
duplicate webhook handling
duplicate ticket issuing
partial issuance
manual review recovery
refund/revocation from ticket_issued
WhatsApp payment-pending messaging
TicketIssue vs DeliveryAttempt ownership
```

The correct understanding must be:

```text
All channels are interfaces.
Sales state transitions are explicit.
Payment verification is backend-controlled.
Inventory safety is preserved.
Ticket issuance is idempotent.
Delivery audit belongs to DeliveryAttempt.
Scanner validity remains protected by existing attendee/scanner path.
```
