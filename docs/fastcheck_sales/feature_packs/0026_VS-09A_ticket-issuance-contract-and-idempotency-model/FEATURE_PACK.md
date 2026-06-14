# FastCheck Sales Feature Planning Pack — VS-09A Ticket Issuance Contract and Idempotency Model

**Pack ID:** `0026_VS-09A_ticket-issuance-contract-and-idempotency-model`  
**Slice:** `VS-09A`  
**Slice name:** Ticket Issuance Contract and Idempotency Model  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** Contract planning pack — no production issuance implementation in this slice  
**Primary area:** Architecture / Tickets / Issuance Idempotency / Cross-Boundary Contract  
**Depends on:** VS-02, VS-07C, VS-08, VS-01D, VS-01F, VS-01G, VS-00A, VS-00B, VS-21A  
**Blocks:** VS-09B, VS-09C, VS-09D, VS-10, VS-11, VS-12, VS-15A, VS-15B, VS-19, VS-22  
**Repository path:** `docs/fastcheck_sales/feature_packs/0026_VS-09A_ticket-issuance-contract-and-idempotency-model/`  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

**Normalization:** Batch `0026_0028`; structural normalization only; source docs are repo-relative; no semantic changes applied.  

---

## 1. Purpose

This pack instructs a coding agent to define the **authoritative ticket issuance contract** before any code creates Sales-paid Attendees or scanner-valid TicketIssue records.

VS-09A must lock the rules for:

```text
who may issue tickets
which service owns issuing
which order/payment/checkout states permit issuing
which transaction or saga model will be used
which DB rows must be locked
which uniqueness keys make issuing retry-safe
how duplicate workers behave
how partial failures recover
how manual_review is entered
how event sync will be triggered later
how scanner-visible behavior remains isolated until VS-10 and VS-15A
```

Critical principle:

```text
VS-09A defines the contract.
VS-09A does not create Attendee rows.
VS-09A does not create TicketIssue rows from paid orders.
VS-09A does not change scanner acceptance.
VS-09A does not enqueue delivery attempts.
```

This pack exists because the next slices cross the most dangerous boundary in the system:

```text
verified paid Sales state
  -> existing Ecto Attendee records
  -> Sales TicketIssue audit records
  -> scanner/mobile-sync visibility
```

If the contract is vague, retries and partial failures can create duplicate tickets, paid orders without tickets, scanner-valid tickets without Sales audit, or customer value after a disputed payment.

---

## 2. Ultimate Outcome

After VS-09A is complete:

```text
There is exactly one approved issuer entrypoint: FastCheck.Tickets.Issuer.issue_order/1 or issue_order/2.
The issuer contract states whether issuing uses one DB transaction or a saga/recovery model.
The issuer preconditions are explicit and testable.
The idempotency keys are explicit and mapped to DB constraints.
The locking strategy is explicit.
The partial-failure recovery strategy is explicit.
The order-level completion rules are explicit for ticket_issued, partially_issued, and manual_review.
The boundary between VS-09B Attendee creation and VS-09C TicketIssue audit linking is explicit.
Duplicate Oban workers are safe by contract.
No controller, webhook, LiveView, or WhatsApp handler may issue tickets directly.
```

The system is then ready for VS-09B to implement the Attendee creation bridge without inventing its own issuance rules.

---

## 3. Scope

### In scope

```text
Create or update the ticket issuance architecture contract document.
Define the approved issuer public API and return shapes.
Define the issuer precondition matrix.
Define the transaction/saga model decision.
Define the row-lock/advisory-lock strategy.
Define idempotency keys and DB uniqueness dependencies.
Define how multi-ticket order lines expand into per-ticket issuance units.
Define partial failure classifications and recovery actions.
Define duplicate worker and retry behavior.
Define order state transition outcomes for ticket_issued, partially_issued, and manual_review.
Define StateTransition audit requirements for issuance actions.
Define the split between VS-09B, VS-09C, and VS-09D.
Add contract-level RED/GREEN tests or documentation checks if the repo has docs/test conventions for architecture contracts.
```

### Out of scope

```text
No Attendee creation.
No TicketIssue creation from orders.
No implementation of FastCheck.Tickets.Issuer issuing behavior.
No IssueTicketsWorker implementation changes except documented contract notes if a stub already exists.
No scanner route or scanner hot-path change.
No Android mobile API change.
No event sync version bump implementation.
No DeliveryAttempt creation.
No secure ticket page.
No WhatsApp or Meta API behavior.
No Paystack webhook/verification change.
No Redis inventory mutation.
No refund or revocation implementation.
No admin UI/manual review actions.
```

---

## 4. Required Pre-Implementation Discovery

Before changing files, the coding agent must inspect the repo and document findings in the final report:

```text
Existing FastCheck.Tickets namespace and whether issuer.ex already exists.
Existing Attendee Ecto schema, context, unique fields, and scanner-visible fields.
Existing Tickera reconciliation origin/source fields from VS-02.
Existing TicketIssue resource fields and indexes from VS-01D / VS-01G / VS-08.
Existing Order, OrderLine, CheckoutSession, PaymentAttempt states and Ash actions from VS-05 / VS-07C.
Existing Oban worker naming and uniqueness conventions.
Existing Repo usage: whether Ash Sales and existing Attendees share the same Repo.
Existing helper for DB locks, optimistic locks, Ecto.Multi, Ash transactions, or advisory locks.
Existing StateTransition recording helper.
Existing telemetry/log-redaction conventions from VS-21A.
Existing tests/factories for Orders, OrderLines, PaymentAttempts, Attendees, and TicketIssues.
```

Discovery decision:

```text
If Sales/Ash and existing Attendees share the same Repo, prefer one DB transaction for issuance.
If they do not share the same Repo, choose a saga/recovery contract with explicit compensation and retry rules.
Do not guess. The final VS-09A output must state which model was selected and why.
```

---

## 5. Approved Issuer Boundary

### Required public entrypoint

Use one deliberate orchestration service:

```text
lib/fastcheck/tickets/issuer.ex
FastCheck.Tickets.Issuer.issue_order(order_id, opts \\ [])
```

Allowed variants:

```text
issue_order(order_id)
issue_order(order_id, actor: system_actor, correlation_id: correlation_id, idempotency_key: idempotency_key)
```

Return shape must be explicit. Recommended shape:

```text
{:ok, %{order_id: ..., status: :ticket_issued, issued_count: n}}
{:ok, %{order_id: ..., status: :already_issued, issued_count: n}}
{:ok, %{order_id: ..., status: :partially_issued, issued_count: n, failed_count: n}}
{:error, {:invalid_order_state, state}}
{:error, {:manual_review_required, reason_code}}
{:error, {:retryable, reason_code}}
{:error, {:permanent, reason_code}}
```

Do not let multiple modules own issuance orchestration:

```text
controllers must not issue tickets
Paystack webhook controllers must not issue tickets
Paystack webhook workers must not issue tickets directly
LiveViews must not issue tickets directly
WhatsApp handlers must not issue tickets directly
admin manual actions must not issue tickets directly
```

Only the approved worker may call the issuer:

```text
FastCheck.Workers.IssueTicketsWorker
  -> FastCheck.Tickets.Issuer.issue_order(order_id, opts)
```

---

## 6. Issuance Preconditions

VS-09A must define these as contract requirements before VS-09B starts.

### Order preconditions

Issuance is allowed only when all of these are true:

```text
Order exists.
Order status is paid_verified or fulfillment_queued according to the approved state matrix.
Order has at least one OrderLine.
Order total and currency were already verified by VS-07B/VS-07C.
Order is not cancelled, expired without approved late-payment recovery, refunded, or already terminal-manual-review.
Order source_channel is one of the approved channels and was set server-side.
Order belongs to the same event/organization scope as all loaded offers and order lines.
```

### Payment preconditions

```text
At least one PaymentAttempt for the order is verified_success.
The verified PaymentAttempt amount matches Order.total_amount_cents.
The verified PaymentAttempt currency matches Order.currency.
Provider reference is linked to the order and not reused for another order.
PaymentAttempt is not amount_mismatch, currency_mismatch, failed, duplicate-only, or manual_review.
```

### Checkout/inventory preconditions

```text
CheckoutSession is paid or in the approved post-verification fulfillment state.
Inventory hold has already been consumed, or VS-07C/VS-14 has recorded the approved late-payment inventory recovery outcome.
Issuer must not directly mutate Redis keys.
Issuer must not blindly issue after expired checkout without the VS-07C payment-after-expiry/manual-review decision.
```

### Attendee protection preconditions

```text
VS-02 origin/source marker fields are present and tested.
Sales-created Attendees can be distinguished from Tickera-created Attendees.
Tickera reconciliation preserves Sales-origin Attendees.
Scanner acceptance fields and scanner_status semantics are known.
```

### Token preconditions

```text
VS-08 ticket_code generation exists.
VS-08 QR token hash/delivery token hash rules exist.
Plaintext delivery token and QR token are never persisted.
```

---

## 7. Transaction or Saga Model

VS-09A must pick one model and document it.

### Preferred model: one Repo transaction

Use this if Ash Sales resources and existing Attendees use the same Repo.

```text
begin transaction
  acquire order-level lock
  reload Order, OrderLines, PaymentAttempt, CheckoutSession
  verify allowed state/preconditions
  calculate issuance units from order lines
  create/reuse Attendee rows idempotently
  create/reuse TicketIssue rows idempotently
  mark Order ticket_issued or partially_issued/manual_review
  append StateTransition rows
  enqueue event sync aggregation after commit
commit
```

Rules:

```text
Do not hold the DB transaction while calling Paystack, Meta, email, WhatsApp, or external systems.
Do not render QR images inside the transaction.
Do not send messages inside the transaction.
Do not perform Redis Lua/key mutation inside the transaction.
Use after-commit enqueue semantics if available for EventSyncVersionAggregatorWorker.
```

### Alternative model: saga/recovery

Use this only if Sales/Ash and Attendees cannot share one transaction.

```text
acquire order-level idempotency lock
mark fulfillment_queued with correlation_id
create/reuse Attendee rows idempotently
create/reuse TicketIssue rows idempotently
complete order state or move to partially_issued/manual_review
record recoverable checkpoints after each successful step
retry from the last completed checkpoint
```

Saga rules:

```text
Every step must be idempotent.
Every step must be recoverable after process crash.
No step may rely on memory-only state.
No step may create customer-visible delivery before both Attendee and TicketIssue links exist.
Manual review must include enough metadata for support to recover or refund.
```

---

## 8. Locking Strategy

Required locks:

| Lock | Purpose | Recommended approach |
|---|---|---|
| Order lock | Prevent duplicate workers issuing same order concurrently. | DB row lock on `sales_orders` or advisory lock keyed by order id/public_reference. |
| OrderLine issuance unit lock | Prevent duplicate tickets per quantity unit. | Unique `sales_order_line_id + line_item_sequence`. |
| Attendee origin reference lock | Prevent duplicate Attendees for one issued unit. | Unique `source + source_reference` or equivalent from VS-02. |
| Ticket code lock | Prevent duplicate ticket codes. | Unique `ticket_code`. |
| TicketIssue attendee lock | Ensure one Sales TicketIssue per Attendee. | Unique `attendee_id where attendee_id is not null`. |
| Worker uniqueness | Prevent unnecessary parallel work. | Oban uniqueness by `sales_order_id`, but do not rely on Oban uniqueness for correctness. |

Rules:

```text
Oban uniqueness reduces noise; DB constraints provide correctness.
Do not rely on “worker runs once.”
Duplicate worker execution must return idempotent success or a retry-safe error.
```

---

## 9. Issuance Unit Model

Each OrderLine expands into deterministic issuance units.

```text
for each order_line:
  line_item_sequence = 1..order_line.quantity
```

Required unique unit identity:

```text
sales_order_line_id + line_item_sequence
```

Recommended origin reference format:

```text
sales:{sales_order_id}:{sales_order_line_id}:{line_item_sequence}
```

Allowed alternative:

```text
sales:{order_public_reference}:{order_line_line_number}:{line_item_sequence}
```

Rules:

```text
line_item_sequence starts at 1 per OrderLine.
line_item_sequence must not be globally incremented.
line_item_sequence must not be derived from current count in a race-prone way.
Retry must calculate the same issuance units every time.
A quantity of 3 must produce exactly 3 deterministic issuance units.
```

---

## 10. Idempotency Keys and Constraints

Required idempotency keys:

```text
sales_order_id
sales_order_line_id
line_item_sequence
ticket_code
attendee_sales_origin_reference
correlation_id
idempotency_key
```

Required or already-planned DB constraints:

```text
sales_ticket_issues.unique(ticket_code)
sales_ticket_issues.unique(sales_order_line_id, line_item_sequence)
sales_ticket_issues.unique(attendee_id) where attendee_id is not null
attendees.unique(source, source_reference) or equivalent Sales-origin unique constraint
orders.unique(public_reference)
payment_attempts.unique(provider, provider_reference)
```

VS-09A must not add broad migrations unless the missing constraint is purely contract/index readiness and already approved by VS-01G/VS-02/VS-08. Prefer documenting missing constraints as blockers for VS-09B/VS-09C.

---

## 11. Partial Failure Model

VS-09A must classify every partial failure.

| Failure | Required contract behavior |
|---|---|
| Order already `ticket_issued` | Return idempotent success. Do not issue again. |
| Existing Attendee found but TicketIssue missing | Link/create missing TicketIssue in VS-09C retry path. |
| TicketIssue exists but Attendee link missing | Move to manual_review unless deterministic attendee can be safely recovered. |
| One ticket in multi-ticket order fails | Mark `partially_issued` or `manual_review` according to matrix. Do not mark full `ticket_issued`. |
| Attendee unique conflict on same source_reference | Treat as idempotent existing unit if data matches. |
| Attendee unique conflict on different customer/order | Manual review; do not overwrite. |
| TicketIssue unique conflict on same order_line/sequence | Treat as idempotent existing unit if data matches. |
| TicketIssue unique conflict on unrelated order | Manual review; do not overwrite. |
| Order transition fails after all units exist | Retry must detect complete issuance and finish order transition. |
| Event sync enqueue fails after commit | Retry/enqueue recovery job; do not duplicate tickets. |
| Process crashes mid-transaction | Transaction rolls back; retry starts cleanly. |
| Process crashes mid-saga | Retry resumes from durable checkpoints. |

Manual review reason codes must be stable strings, for example:

```text
issuer_attendee_conflict
issuer_ticket_issue_conflict
issuer_partial_attendee_created
issuer_partial_ticket_issue_created
issuer_state_transition_failed
issuer_event_sync_enqueue_failed
issuer_unrecoverable_invariant_violation
issuer_inventory_not_confirmed
issuer_invalid_payment_state
```

---

## 12. State Transition Contract

Required Order outcomes:

| Condition | Order outcome |
|---|---|
| All issuance units completed and linked | `ticket_issued` |
| Some issuance units completed, some recoverably failed | `partially_issued` or `manual_review` per approved matrix |
| Preconditions fail before any customer value exists | stay current or `manual_review` with reason |
| Existing full issuance detected on retry | keep/mark `ticket_issued` idempotently |
| Duplicate worker after issued | idempotent success, no new Attendee/TicketIssue |

Required TicketIssue outcomes for later slices:

```text
pending -> issued
issued -> manual_review only for support/investigation
issued -> revoked only through VS-15A core revocation path
```

Required StateTransition metadata:

```text
entity_type
entity_id
from_state
to_state
reason
actor_type = system unless manual/admin recovery
correlation_id
idempotency_key
source = issue_tickets_worker | tickets_issuer
metadata.issued_count
metadata.expected_count
metadata.failed_count
metadata.reason_code when relevant
```

---

## 13. Worker Contract

Preferred worker:

```text
lib/fastcheck/workers/issue_tickets_worker.ex
FastCheck.Workers.IssueTicketsWorker
```

Required worker semantics:

```text
Queue: ticketing
Uniqueness: by sales_order_id
Retry: safe forever for transient/recoverable failures
Idempotency: mandatory
Load fresh state on every execution
Never trust arguments except order_id/correlation_id/idempotency_key
Never issue directly in payment/webhook worker
Never deliver tickets directly after issuing; delivery is a later worker/flow
```

Worker output must not include:

```text
buyer phone/email
plaintext delivery token
plaintext QR token
raw Paystack payload
raw WhatsApp payload
authorization URL
access code
```

---

## 14. Recommended Files

### Contract/docs files

```text
docs/fastcheck_sales/VS-09A_ticket_issuance_contract.md
docs/fastcheck_sales/ticket_issuance_failure_matrix.md
docs/fastcheck_sales/ticket_issuance_idempotency_keys.md
```

### Optional stub/spec files only if project convention supports explicit behaviours

```text
lib/fastcheck/tickets/issuer.ex                 # contract/stub only; no issuing behavior yet
lib/fastcheck/tickets/issuer_contract.ex        # optional behaviour/spec module if useful
```

### Preferred test files

```text
test/fastcheck/tickets/issuer_contract_test.exs
test/fastcheck/tickets/issuer_idempotency_contract_test.exs
test/fastcheck/tickets/issuer_boundary_test.exs
test/fastcheck/tickets/issuer_partial_failure_contract_test.exs
test/fastcheck/workers/issue_tickets_worker_contract_test.exs
```

Tests in VS-09A should verify the contract and boundaries. They should not require a full ticket issuance implementation until VS-09B/VS-09C/VS-09D.

---

## 15. Ash Resource and Domain Details

### Ash domain

```text
FastCheck.Sales
```

### Ash resources referenced by contract

```text
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.TicketIssue
FastCheck.Sales.StateTransition
```

### Existing Ecto systems referenced by contract

```text
FastCheck.Attendees
FastCheck.Attendees.Reconciliation
FastCheck.Attendees.Scan
FastCheck.Events.Sync
```

### Plain modules referenced by contract

```text
FastCheck.Tickets.Issuer
FastCheck.Tickets.CodeGenerator
FastCheck.Tickets.QrPayload
FastCheck.Tickets.DeliveryToken
FastCheck.Workers.IssueTicketsWorker
FastCheck.Workers.EventSyncVersionAggregatorWorker
```

### Resources not to mutate in VS-09A

```text
No Ash resource action implementation changes except contract-safe state/action documentation if already expected.
No Attendee schema mutation unless VS-02 explicitly left a missing index/constraint blocker and the user approves.
No scanner/mobile route mutation.
No Paystack/WhatsApp/Meta mutation.
No DeliveryAttempt mutation.
```

---

## 16. RED / GREEN Test Plan

### Contract presence tests

```text
RED: no issuer contract document exists.
GREEN: docs/fastcheck_sales/VS-09A_ticket_issuance_contract.md exists and names the selected transaction/saga model.

RED: issuer preconditions are not listed.
GREEN: contract lists Order, PaymentAttempt, CheckoutSession/inventory, Attendee origin, and token preconditions.

RED: partial failure matrix is absent.
GREEN: contract has explicit outcomes for partial attendee creation, partial TicketIssue creation, duplicate worker, and order transition failure.
```

### Boundary tests

```text
RED: controller, webhook, LiveView, WhatsApp handler, or payment worker directly creates Attendee or TicketIssue records.
GREEN: only FastCheck.Tickets.Issuer is allowed to coordinate future issuing.

RED: VS-09A creates Attendee rows or TicketIssue rows from paid orders.
GREEN: VS-09A only defines contract, docs, optional stubs/specs, and contract tests.

RED: issuer contract performs Paystack verification or reads raw webhook payloads.
GREEN: issuer requires already-verified payment state from VS-07B/VS-07C.

RED: issuer contract mutates Redis inventory directly.
GREEN: issuer requires inventory/checkout state already resolved and never mutates Redis keys.
```

### Idempotency tests

```text
RED: duplicate IssueTicketsWorker execution can create duplicate issuance units by contract.
GREEN: DB uniqueness and deterministic issuance units make duplicate worker execution idempotent.

RED: line_item_sequence is generated by count-at-runtime and can race.
GREEN: line_item_sequence is deterministic from 1..order_line.quantity.

RED: order already ticket_issued returns an error that causes retry loops.
GREEN: order already ticket_issued returns idempotent success.
```

### Partial-failure tests

```text
RED: existing Attendee without TicketIssue has no recovery path.
GREEN: retry path links existing Attendee to TicketIssue or moves to manual_review with reason.

RED: TicketIssue exists but order transition failed and retry issues more tickets.
GREEN: retry detects existing units and completes state transition without duplicates.

RED: one failed ticket in a multi-ticket order marks full ticket_issued.
GREEN: partial issuance becomes partially_issued or manual_review with expected/issued/failed counts.
```

### State/audit tests

```text
RED: issuance state transition has no StateTransition audit row.
GREEN: every issuance outcome records StateTransition with correlation_id/idempotency_key.

RED: manual_review outcome has no reason code.
GREEN: manual_review has stable reason_code and support metadata.
```

### Security/logging tests

```text
RED: issuer logs buyer email, buyer phone, plaintext delivery token, QR token, Paystack access code, authorization URL, or raw provider payload.
GREEN: issuer logs only sanitized order id/public reference, correlation id, counts, and reason codes.
```

---

## 17. Performance and Scaling Review

### Data layer classification

| Data | Layer | Rule |
|---|---|---|
| Issuance contract/docs | Cold | Stored in repo docs. |
| Order / OrderLine / PaymentAttempt / CheckoutSession | Cold durable truth | Loaded by indexed id/status paths. |
| Attendee records | Cold durable scanner-visible truth | Mutated only in VS-09B under contract. |
| TicketIssue records | Cold durable Sales audit | Mutated only in VS-09C under contract. |
| IssueTicketsWorker uniqueness | Hot coordination | Oban uniqueness by sales_order_id, but DB constraints remain correctness layer. |
| Event sync aggregation | Hot/warm sync coordination | Deferred to VS-10; enqueue after commit only. |

### Required indexes / constraints

```text
sales_orders: unique(public_reference), index(status, fulfillment_queued_at)
sales_order_lines: unique(sales_order_id, line_number), index(sales_order_id)
sales_payment_attempts: unique(provider, provider_reference), index(sales_order_id, status)
sales_ticket_issues: unique(ticket_code)
sales_ticket_issues: unique(sales_order_line_id, line_item_sequence)
sales_ticket_issues: unique(attendee_id) where attendee_id is not null
attendees: unique(source, source_reference) or approved VS-02 equivalent
state_transitions: index(entity_type, entity_id, inserted_at), index(correlation_id)
```

### Caching / Redis rules

```text
No Cachex or Redis cache is required for VS-09A contract docs.
Issuer implementation in later slices must not read live availability from Postgres for flash-sale decisions.
Issuer implementation must not directly mutate Redis inventory keys.
Any inventory consume/recovery state must come from VS-07C/VS-14/ReservationLedger contract.
```

### 100k-concurrency safety

```text
The issuance path is not a public hot checkout path, but it must be safe under worker spikes.
Use DB constraints and locks for correctness, not in-memory process assumptions.
Use Oban uniqueness to reduce duplicate work, not to guarantee correctness.
Avoid large table scans when finding fulfillment_queued orders.
Batch fulfillment enqueueing must use indexed query paths and bounded batch sizes.
Do not load all order lines/tickets/events into memory for dashboards or recovery.
```

### PubSub and invalidation rules

```text
No PubSub broadcasts required in VS-09A.
Future VS-09B/VS-09C may broadcast admin/order status updates only after durable state changes.
Future VS-10 handles scanner/mobile sync version aggregation.
Future VS-11/VS-15A handle secure ticket page and revocation cache invalidation.
```

---

## 18. Security and PII Rules

```text
Do not log buyer_name, buyer_phone, buyer_email, recipient, plaintext QR token, plaintext delivery token, raw Paystack payload, raw WhatsApp payload, access_code, or authorization_url.
Do not expose raw provider payloads in issuer errors.
Do not return plaintext tokens from issuer contract except later one-time delivery preparation flow explicitly owned by future delivery slices.
Do not embed PII in source_reference, ticket_code, qr_token, or delivery_token.
Manual review metadata must support debugging without dumping raw PII/provider payloads.
```

---

## 19. Failure Modes and Risk Review

| Risk | Control |
|---|---|
| Duplicate worker creates duplicate tickets | DB locks + unique issuance unit + idempotent return. |
| Attendee created but TicketIssue missing | Retry must link existing Attendee or manual_review with reason. |
| TicketIssue created but Attendee invalid/missing | Retry recovery if deterministic; otherwise manual_review. |
| Order marked issued before all units exist | Completion rule checks expected vs completed units. |
| Payment reversed/mismatched after issuance | Out of scope; VS-15A/VS-15B revocation/refund path handles scanner visibility. |
| Event sync enqueue fails | Ticket state remains durable; enqueue recovery/retry path required. |
| Scanner accepts a ticket with no Sales audit | Contract requires Attendee and TicketIssue linking before customer value delivery. |
| Token leak through logs | Log redaction tests and no plaintext token persistence. |
| Long DB locks under worker burst | Keep transaction focused, no external IO inside transaction, indexed loads only. |
| Multi-tenant leakage | Enforce organization/event scope in issuer preconditions if tenanting exists. |

---

## 20. Acceptance Criteria

This slice is Done only when:

```text
A VS-09A ticket issuance contract document exists.
The selected transaction/saga model is explicitly chosen.
The approved issuer entrypoint and return shapes are documented.
Order/payment/checkout/inventory/token/attendee preconditions are documented.
The deterministic issuance unit model is documented.
Idempotency keys and required DB constraints are listed.
Duplicate worker behavior is documented.
Partial failure and recovery behavior is documented.
Manual review reason codes are documented.
StateTransition audit requirements are documented.
Boundary tests or documentation checks prove no issuing implementation slipped into VS-09A.
No Attendee creation, TicketIssue creation from paid orders, scanner change, Paystack change, WhatsApp change, delivery change, or Redis mutation is added.
The final report lists all discovered repo conventions and any blockers for VS-09B/VS-09C.
```

---

## 21. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Define the VS-09A ticket issuance contract and idempotency model without implementing ticket issuance. |
| Objective | Lock the only safe cross-boundary pattern for converting verified paid orders into existing Attendee rows and Sales TicketIssue audit rows, so VS-09B/VS-09C can implement issuing without duplicate tickets, hidden side effects, or scanner instability. |
| Output | Create/update `docs/fastcheck_sales/VS-09A_ticket_issuance_contract.md`, `docs/fastcheck_sales/ticket_issuance_failure_matrix.md`, and `docs/fastcheck_sales/ticket_issuance_idempotency_keys.md`. Add contract-level tests under `test/fastcheck/tickets/` only if the repo has existing conventions for documentation/architecture contract checks. Final report must list selected transaction/saga model, issuer entrypoint, preconditions, idempotency keys, locks, partial-failure rules, and blockers for VS-09B/VS-09C. |
| Note | Do not create Attendees or TicketIssues from orders. Do not implement `IssueTicketsWorker` behavior. Do not mutate scanner/mobile sync, Paystack, WhatsApp, DeliveryAttempt, or Redis inventory. Approved future issuer entrypoint is `FastCheck.Tickets.Issuer.issue_order/1` or `/2`. If Sales/Ash and Attendees share one Repo, prefer a single transaction with order lock; otherwise document a saga with durable checkpoints. Required constraints: `unique(sales_order_line_id, line_item_sequence)`, `unique(ticket_code)`, `unique(attendee_id) where attendee_id is not null`, and Attendee `unique(source, source_reference)` or VS-02 equivalent. Caching: none in VS-09A. TTL: none in VS-09A. Redis: no direct mutation; future issuer must consume only the approved checkout/inventory state. PubSub: none in VS-09A; future sync handled by VS-10. Logs must redact PII, tokens, provider payloads, Paystack access codes, and authorization URLs. |

---

## 22. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales slice VS-09A — Ticket Issuance Contract and Idempotency Model.

Your task is contract definition only. Do not implement production ticket issuance.

Read the latest FastCheck Sales architecture/roadmap docs and inspect the repo for:
- FastCheck.Tickets namespace
- existing Attendee Ecto schema/context
- VS-02 Sales attendee origin protection fields/constraints
- Sales Order, OrderLine, CheckoutSession, PaymentAttempt, TicketIssue, StateTransition resources
- existing Oban worker conventions
- whether Ash Sales and Attendees use the same Repo
- existing lock/Ecto.Multi/Ash transaction helpers
- existing telemetry/log-redaction helpers

Create/update these docs:
- docs/fastcheck_sales/VS-09A_ticket_issuance_contract.md
- docs/fastcheck_sales/ticket_issuance_failure_matrix.md
- docs/fastcheck_sales/ticket_issuance_idempotency_keys.md

Define:
- approved issuer entrypoint: FastCheck.Tickets.Issuer.issue_order/1 or /2
- selected transaction/saga model and why
- issuer preconditions
- row/advisory lock strategy
- deterministic issuance unit model using sales_order_line_id + line_item_sequence
- idempotency keys and required DB constraints
- partial failure recovery rules
- duplicate worker behavior
- order state outcomes
- StateTransition audit metadata
- strict boundaries for VS-09B, VS-09C, and VS-09D

Add contract-level tests only if the repo already supports documentation/architecture contract tests. Tests must prove the contract exists and that no controller/webhook/LiveView/WhatsApp/payment worker directly owns issuing.

Forbidden in this slice:
- no Attendee creation
- no TicketIssue creation from paid orders
- no scanner/mobile sync changes
- no Paystack or WhatsApp changes
- no DeliveryAttempt creation
- no Redis inventory mutation
- no secure ticket page
- no admin refund/revoke actions

Final report must include files changed, selected model, discovered repo conventions, RED/GREEN test results, and blockers for VS-09B/VS-09C.
```

---

## 23. Human Review Checklist

```text
[ ] VS-09A did not implement actual ticket issuance.
[ ] Approved issuer entrypoint is clear and singular.
[ ] Transaction vs saga model is selected based on repo reality.
[ ] Preconditions include order, payment, checkout/inventory, attendee origin, and token readiness.
[ ] Deterministic issuance unit model uses line_item_sequence per order line.
[ ] Idempotency keys and DB constraints are explicit.
[ ] Duplicate worker behavior returns idempotent success or safe retry/manual_review.
[ ] Partial failure matrix covers Attendee-only, TicketIssue-only, order-transition failure, and event-sync enqueue failure.
[ ] Manual review reason codes are stable and supportable.
[ ] StateTransition audit metadata is explicit.
[ ] No scanner, mobile sync, Paystack, WhatsApp, DeliveryAttempt, Redis, or secure ticket page behavior was added.
[ ] Logs and errors avoid PII, plaintext tokens, provider payloads, access codes, and authorization URLs.
[ ] Blockers for VS-09B and VS-09C are documented.
```

---

## 24. Next Slice

```text
VS-09B — Attendee Creation Bridge
```
