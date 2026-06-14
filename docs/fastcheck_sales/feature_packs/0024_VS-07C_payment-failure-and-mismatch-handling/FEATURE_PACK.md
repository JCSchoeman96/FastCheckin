# FastCheck Sales Feature Planning Pack — VS-07C Payment Failure and Mismatch Handling

**Pack ID:** `0024_VS-07C_payment-failure-and-mismatch-handling`  
**Slice:** `VS-07C`  
**Slice name:** Payment Failure and Mismatch Handling  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Repository path:** `docs/fastcheck_sales/feature_packs/0024_VS-07C_payment-failure-and-mismatch-handling/`  
**Status:** Implementation planning pack — implementation allowed inside this slice only  
**Primary area:** Payments / State / Manual Review / Expired Checkout / Idempotency  
**Depends on:** VS-07B, VS-07A, VS-06C, VS-06B, VS-06A, VS-05, VS-04B, VS-04A, VS-01C, VS-01F, VS-01G, VS-00A, VS-00B, VS-00C, VS-21A  
**Blocks:** VS-09A, VS-12, VS-13, VS-19, VS-21B, VS-22  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack instructs a coding agent to implement the **payment failure, mismatch, duplicate, unmatched-event, and expired-checkout outcome layer** after Paystack server-side verification exists.

VS-07B classified transaction trust. VS-07C decides what FastCheck should do when the verified or attempted payment outcome is not the simple happy path.

Critical principle:

```text
Failure handling must protect money, inventory, and customer trust.
Mismatch handling must never issue tickets automatically.
Expired checkout recovery must never oversell.
Duplicate payment/webhook handling must be idempotent forever.
Manual review must be auditable and constrained.
```

VS-07C owns:

```text
duplicate webhook/payment classification
amount mismatch outcome
currency mismatch outcome
reference mismatch outcome
unmatched PaymentEvent outcome
provider failed/abandoned outcome
expired checkout with verified payment outcome
manual_review transitions for payments/orders/checkout sessions/payment events
customer-safe payment status semantics
operator/admin review-ready state
```

VS-07C does **not** own:

```text
ticket issuance
Attendee creation
scanner visibility
admin manual-review UI actions
refund provider API
WhatsApp conversation flow
secure ticket page
```

---

## 2. Ultimate Outcome

After VS-07C is complete:

```text
A duplicate Paystack webhook or duplicate verification worker does not change a terminal successful outcome.
Amount, currency, and reference mismatches move PaymentAttempt/Order/PaymentEvent into manual_review with audit reasons.
Unmatched PaymentEvents are retained, retryable, and visible for later admin/dashboard work.
Expired checkout + verified payment follows the approved payment-after-expiry policy without blindly issuing tickets.
If inventory can still be safely recovered, the system may re-reserve/consume through the approved ReservationLedger boundary and move back toward fulfillment-ready state.
If inventory is unavailable or ledger health is unknown, the order/payment moves to manual_review and no ticket is issued.
Provider failure/timeouts do not erase local durable state or customer payment evidence.
No customer-facing state says “no payment received” after verified payment exists.
Every meaningful transition appends StateTransition records with correlation/idempotency metadata.
All logs are PII/secret/provider-payload safe.
```

The system is then ready for VS-09A to define ticket issuance idempotency and for VS-12 to display payment/support status safely.

---

## 3. Scope

### In scope

```text
Add or finalize a payment outcome handler/orchestration module.
Handle duplicate PaymentEvent and duplicate verification outcomes.
Handle amount mismatch, currency mismatch, reference mismatch, and provider failed outcomes.
Handle unmatched PaymentEvent records without deleting them.
Handle expired checkout + verified payment according to VS-00A payment-after-expiry policy.
Use ReservationLedger only for approved late-payment inventory re-reserve/consume checks where the policy allows it.
Move PaymentAttempt, PaymentEvent, Order, and CheckoutSession into manual_review or safe idempotent states through named Ash actions only.
Record StateTransition rows for all order/payment/checkout/session state changes.
Add structured failure_reason/manual_review_reason codes.
Add telemetry for mismatch, duplicate, unmatched, expired-late-payment, and manual-review outcomes.
Add RED/GREEN tests for realistic failure paths and boundary creep.
```

### Out of scope

```text
No Paystack webhook controller redesign except small integration gaps discovered from VS-07A.
No Paystack transaction initialization changes.
No Paystack transaction verification client changes except using existing VS-07B result classifications.
No Paystack refund API.
No customer-facing refund flow.
No ticket issuance.
No TicketIssue creation.
No Attendee creation or mutation.
No scanner/mobile sync changes.
No QR/ticket token generation.
No DeliveryAttempt creation.
No WhatsApp/Meta messaging.
No admin manual-review UI.
No public payment status page unless it already exists and only needs safe read-state wording.
No direct Redis key mutation outside ReservationLedger.
No generic status update helpers.
```

---

## 4. Required Pre-Implementation Discovery

Before changing code, the agent must inspect the repository and document findings in the final report:

```text
Existing VS-07B payment verification orchestration module and result shape.
Existing VerifyPaymentWorker retry/idempotency conventions.
Existing PaymentAttempt status actions and mismatch actions.
Existing PaymentEvent processing actions and dedupe fields.
Existing Order state actions and manual_review transition rules.
Existing CheckoutSession state actions and expiry/release/paid states.
Existing StateTransition helper/action conventions.
Existing ReservationLedger reserve/consume/release API and idempotency arguments.
Existing checkout expiry behavior from VS-05/VS-14 planning if present.
Existing telemetry/log redaction helper conventions from VS-21A.
Existing policy actor conventions from VS-01F.
Existing test helpers/factories for Order, CheckoutSession, PaymentAttempt, PaymentEvent, and Redis ledger tests.
```

Do not invent new state values if approved state machine values already exist.

---

## 5. Outcome Classification Model

Implement one explicit internal classification layer. Do not spread outcome decisions across controllers, workers, LiveViews, and resource actions.

Recommended module:

```text
lib/fastcheck/payments/paystack/payment_outcomes.ex
```

Recommended result names:

```text
:verified_active_checkout
:verified_expired_checkout_inventory_recovered
:verified_expired_checkout_inventory_unavailable
:verified_expired_checkout_ledger_unhealthy
:duplicate_already_verified
:duplicate_already_issued_future_safe
:amount_mismatch
:currency_mismatch
:reference_mismatch
:provider_failed
:provider_pending_or_abandoned
:unmatched_event
:invalid_signature_ignored_for_processing
:manual_review_required
```

Rules:

```text
Classification must be deterministic for the same inputs.
Classification must not issue tickets.
Classification must not send customer messages.
Classification must not directly mutate Redis keys.
Classification may call ReservationLedger through the approved API only when late-payment recovery policy requires checking/recovering inventory.
Classification must return enough data for audit metadata without leaking raw payloads.
```

---

## 6. Domain and Boundary Details

### Ash domain

```text
FastCheck.Sales
```

### Ash resources touched

```text
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.PaymentEvent
FastCheck.Sales.Order
FastCheck.Sales.CheckoutSession
FastCheck.Sales.StateTransition
```

### Ash resources explicitly forbidden from mutation

```text
FastCheck.Sales.OrderLine
FastCheck.Sales.TicketOffer
FastCheck.Sales.TicketIssue
FastCheck.Sales.DeliveryAttempt
FastCheck.Sales.Conversation
```

### Existing non-Ash systems forbidden from mutation

```text
FastCheck.Attendees
FastCheck.Attendees.Scan
FastCheck.Attendees.Reconciliation
FastCheck.Events.Sync
Android mobile API
Scanner routes and scanner hot path
```

### Plain Elixir modules expected

```text
FastCheck.Payments.Paystack.PaymentOutcomes
FastCheck.Payments.Paystack.PaymentOutcomeHandler
FastCheck.Payments.Paystack.PaymentFailureReason
FastCheck.Workers.VerifyPaymentWorker      # updated only if needed to call outcome handler
FastCheck.Sales.Inventory.ReservationLedger # used only through approved public API
```

### Preferred files

```text
lib/fastcheck/payments/paystack/payment_outcomes.ex
lib/fastcheck/payments/paystack/payment_outcome_handler.ex
lib/fastcheck/payments/paystack/payment_failure_reason.ex
lib/fastcheck/workers/verify_payment_worker.ex
```

### Preferred test files

```text
test/fastcheck/payments/paystack/payment_outcomes_test.exs
test/fastcheck/payments/paystack/payment_outcome_handler_test.exs
test/fastcheck/payments/paystack/payment_failure_and_mismatch_test.exs
test/fastcheck/payments/paystack/payment_after_expiry_test.exs
test/fastcheck/payments/paystack/payment_duplicate_idempotency_test.exs
test/fastcheck/payments/paystack/payment_unmatched_event_test.exs
test/fastcheck/payments/paystack/payment_policy_test.exs
test/fastcheck/payments/paystack/payment_security_test.exs
test/fastcheck/payments/paystack/payment_boundary_test.exs
```

---

## 7. Required Outcome Rules

## 7.1 Duplicate webhook/payment outcome

When the same Paystack event/reference is received or processed more than once:

```text
If PaymentAttempt is already verified_success and Order is already paid_verified or later, return idempotent success.
If PaymentEvent is already processed, mark duplicate or no-op according to existing action names.
Do not downgrade PaymentAttempt from verified_success.
Do not overwrite verified_at/provider_paid_at with weaker data.
Do not issue tickets.
Do not enqueue ticket issuance in this slice.
Record duplicate outcome metadata for audit/telemetry.
```

### Tests

```text
RED: duplicate webhook after verified_success tries to mutate payment state again.
GREEN: duplicate webhook returns idempotent success and records duplicate/ignored outcome.
RED: duplicate worker creates another state transition to paid_verified.
GREEN: duplicate worker produces no harmful duplicate transition or only a clear duplicate audit entry.
```

## 7.2 Amount mismatch outcome

When provider amount does not match local durable amount:

```text
PaymentAttempt -> verified_amount_mismatch or manual_review according to approved actions.
Order -> manual_review unless already in a terminal safer state requiring explicit recovery.
PaymentEvent -> processed/manual_review with reason amount_mismatch.
CheckoutSession -> manual_review or remain unchanged if safer and already terminal.
No ticket issuance.
No inventory consume.
No customer “paid and ticket ready” state.
StateTransition reason must include amount_mismatch and sanitized local/provider amount metadata.
```

### Tests

```text
RED: amount mismatch marks order paid_verified.
GREEN: amount mismatch moves payment/order to manual_review and does not issue/fulfill.
RED: amount mismatch logs raw payload/authorization_url/access_code.
GREEN: logs include only redacted/sanitized metadata.
```

## 7.3 Currency mismatch outcome

When provider currency does not match local durable currency:

```text
PaymentAttempt -> verified_currency_mismatch or manual_review.
Order -> manual_review.
PaymentEvent -> processed/manual_review with reason currency_mismatch.
No ticket issuance.
No inventory consume.
No silent currency normalization.
```

### Tests

```text
RED: currency mismatch treats ZAR and NGN as interchangeable.
GREEN: currency mismatch goes to manual_review and preserves local currency truth.
```

## 7.4 Reference mismatch outcome

When provider reference or local ownership does not match:

```text
Do not attach payment to the wrong order.
Do not search by buyer email/phone as fallback authority.
PaymentEvent -> unmatched or manual_review.
Known PaymentAttempt -> manual_review if local reference ownership is suspicious.
Order should not move paid_verified.
```

### Tests

```text
RED: provider reference mismatch updates the wrong order.
GREEN: mismatch is unmatched/manual_review and no order is paid.
```

## 7.5 Provider failed / pending / abandoned outcome

When Paystack verification indicates failure, abandoned, pending, or non-success:

```text
PaymentAttempt -> failed or manual_review depending provider result and retryability.
Order remains awaiting_payment/payment_pending unless the state matrix allows failure/manual_review.
CheckoutSession remains active until expiry policy handles it, unless explicitly failed.
PaymentEvent -> processed or failed with retry metadata.
No ticket issuance.
No inventory consume.
```

Retryable vs non-retryable split:

```text
network timeout -> retry worker, no durable failed payment unless retry budget exhausted
malformed provider response -> failed/manual_review with sanitized reason
provider status failed/abandoned -> mark failed if final, else keep pending/retryable
```

### Tests

```text
RED: timeout permanently fails order immediately.
GREEN: timeout retries safely and does not erase durable attempt state.
RED: abandoned provider status marks order paid_verified.
GREEN: abandoned status marks payment failed or pending according to matrix.
```

## 7.6 Unmatched PaymentEvent outcome

When a valid webhook event has no local PaymentAttempt yet:

```text
PaymentEvent -> unmatched.
Keep raw/sanitized payload according to VS-00B retention policy.
Do not delete the event.
Do not create an Order from webhook payload.
Do not create PaymentAttempt from webhook payload unless a later explicit reconciliation slice allows it.
Allow retry/reprocessing once local PaymentAttempt exists.
Expose enough state for future admin dashboard/manual review.
```

### Tests

```text
RED: unmatched event is deleted after processing.
GREEN: unmatched event remains queryable and retryable.
RED: unmatched event creates order/payment attempt from provider payload.
GREEN: unmatched event stays unmatched without creating value-delivery state.
```

## 7.7 Expired checkout + verified payment outcome

Payments may verify after checkout or Redis holds expire. VS-07C must implement the policy hooks without bypassing inventory authority.

Required policy:

| Case | Required behavior |
|---|---|
| Payment verified before hold expiry | Normal success path from VS-07B; no special recovery. |
| Payment verified after hold expiry and inventory is still available | Re-reserve/consume through `ReservationLedger`; then move order toward paid/fulfillment-ready state. Do **not** issue tickets in this slice. |
| Payment verified after hold expiry and inventory is unavailable | Move order/payment/checkout to `manual_review`; do not issue automatically. |
| Payment verified after hold expiry and Redis/ledger health is unknown | Fail closed into `manual_review`; do not promise ticket. |
| Webhook arrives after order expired | Verify payment, record event, then apply payment-after-expiry policy. |
| Duplicate payment/webhook for already-issued future state | Idempotent duplicate success only; do not issue again. |
| Amount/currency/reference mismatch | Manual review. Do not issue ticket. |

Rules:

```text
All inventory recovery must go through FastCheck.Sales.Inventory.ReservationLedger.
Do not mutate Redis keys directly.
Do not rely on Postgres configured_quantity_available as live availability.
Do not issue tickets in this slice.
If recovery succeeds, the next slice still needs issuance idempotency before tickets are created.
If recovery fails, customer-facing state must not say “no payment received”. It should say paid/manual review/pending support where applicable.
```

### Tests

```text
RED: verified payment after expiry issues a ticket directly.
GREEN: no ticket issue occurs; order reaches safe paid/manual-review/fulfillment-ready state.
RED: verified late payment with no inventory still marks checkout paid and fulfillment-ready.
GREEN: no-inventory case moves to manual_review.
RED: Redis unavailable during late-payment recovery proceeds anyway.
GREEN: Redis unavailable fails closed to manual_review.
```

---

## 8. State Transition Expectations

### PaymentAttempt transitions owned or finalized here

```text
verification_started -> verified_amount_mismatch
verification_started -> verified_currency_mismatch
verification_started -> failed
verification_started -> duplicate
verification_started -> manual_review
verified_success -> duplicate/idempotent no-op
verified_amount_mismatch -> manual_review
verified_currency_mismatch -> manual_review
failed -> manual_review where retry/recovery requires human review
manual_review -> no automatic exit in this slice
```

### PaymentEvent transitions owned or finalized here

```text
processing_started -> processed
processing_started -> unmatched
processing_started -> failed
processing_started -> duplicate
unmatched -> processing_started on retry/reprocess
unmatched -> manual_review where configured
failed -> processing_started on retry
failed -> manual_review after retry exhaustion
processed -> duplicate/idempotent no-op
```

### Order transitions owned or finalized here

```text
payment_pending -> manual_review
paid_unverified -> manual_review
paid_verified -> manual_review only for explicit safety issue before fulfillment
expired -> manual_review when verified late payment cannot be fulfilled safely
expired -> paid_verified/fulfillment-ready only through approved late-payment recovery and state matrix
awaiting_payment -> manual_review for verified mismatch or suspicious provider result
```

### CheckoutSession transitions owned or finalized here

```text
payment_started -> manual_review
expired -> manual_review for verified late payment without safe inventory recovery
expired -> paid or recovery state only if inventory recovery succeeds and matrix allows it
failed -> manual_review where provider/local state conflicts
paid -> idempotent no-op on duplicates
```

Rules:

```text
Every state transition must append StateTransition.
Manual review transitions require non-empty reason code.
Do not introduce generic update_status actions.
Do not bypass Ash policies/actions with direct Repo updates.
```

---

## 9. Manual Review Reason Codes

Use stable machine-readable reason codes. Do not rely only on free-text strings.

Recommended reason codes:

```text
payment_amount_mismatch
payment_currency_mismatch
payment_reference_mismatch
payment_provider_failed
payment_provider_pending_timeout
payment_event_unmatched
payment_duplicate_suspicious
late_payment_inventory_unavailable
late_payment_inventory_ledger_unhealthy
late_payment_recovery_failed
payment_raw_payload_invalid
payment_state_conflict
payment_manual_operator_review_required
```

Rules:

```text
Reason code is required for any manual_review transition.
Optional human-readable reason may be added, but code is the durable classifier.
Do not include raw payload, full phone/email, access_code, authorization_url, or plaintext token in reason text.
```

---

## 10. Data, Index, and Migration Notes

This slice should avoid new migrations unless existing skeletons lack required fields.

Allowed migration additions only if missing:

```text
PaymentAttempt.failure_code
PaymentAttempt.failure_message
PaymentAttempt.manual_review_reason
PaymentAttempt.last_verified_at
PaymentAttempt.verification_attempt_count
PaymentEvent.processing_attempt_count
PaymentEvent.last_processing_error
PaymentEvent.last_processing_error_at
Order.manual_review_reason
Order.last_error_code
Order.last_error_message
CheckoutSession.state_data/manual_review metadata equivalent
```

Index expectations:

```text
sales_payment_attempts(provider, provider_reference) unique already exists.
sales_payment_attempts(sales_order_id, status) already exists.
sales_payment_events(provider, provider_event_id) unique already exists.
sales_payment_events(provider_reference) index already exists.
sales_payment_events(processing_status, inserted_at) index already exists.
sales_orders(event_id, status, inserted_at) already exists.
sales_orders(expires_at, status) already exists.
sales_checkout_sessions(status, expires_at) already exists.
```

Rules:

```text
Do not add broad unindexed admin queries.
Do not add large table scans to payment workers.
Use indexed references/statuses for lookup and retry queues.
If adding fields, update Ash resource attributes, migrations, tests, and pack/report notes together.
```

---

## 11. Redis / Cache / PubSub / Oban Impact

### Redis impact

```text
Use ReservationLedger only for approved late-payment inventory recovery.
Do not mutate Redis inventory keys directly.
Do not use Redis as the payment source of truth.
Use Redis dedupe keys from VS-07A/VS-07B if already present.
Use Redis locks only to prevent duplicate processing; DB uniqueness and state checks remain durable safety.
```

Suggested lock/dedupe keys if not already standardized:

```text
sales:payment:verify:{provider}:{provider_reference}:lock       TTL 60s
sales:payment:event:{provider}:{provider_event_id}:dedupe       TTL 24h+
sales:payment:outcome:{provider}:{provider_reference}:dedupe    TTL 24h+
```

### Cache impact

```text
Invalidate admin order/payment dashboard cache on manual_review/failed/duplicate/unmatched/payment state changes.
Do not cache raw provider payloads.
Do not cache authorization_url/access_code.
```

### PubSub impact

Broadcast only safe operational/admin status updates:

```text
payments:mismatch
payments:manual_review
payments:unmatched_event
payments:duplicate_ignored
payments:late_payment_recovered
payments:late_payment_manual_review
```

Do not broadcast raw payloads or PII.

### Oban impact

```text
VerifyPaymentWorker may call outcome handler.
PaystackWebhookWorker may classify event as unmatched/duplicate/failed after verification attempt.
Jobs must be unique by provider_reference or payment_event_id where appropriate.
Workers must load fresh state before mutating.
Workers must be idempotent under duplicate execution.
Retry transient provider/network/DB errors; do not retry deterministic amount/currency/reference mismatch forever.
```

---

## 12. Security, PII, and Logging Rules

Never log:

```text
raw Paystack payload
authorization_url
access_code
customer phone
customer email
delivery token
qr token
full provider response
full request headers
Paystack secret key
```

Allowed sanitized audit metadata:

```text
provider
provider_reference hash or safe opaque reference if already customer-safe
local_amount_cents
provider_amount_cents
local_currency
provider_currency
status classifier
reason_code
payment_attempt_id
payment_event_id
order_public_reference
correlation_id
idempotency_key hash/suffix only
```

Rules:

```text
Operator cannot view raw provider payloads by default.
Admin/system raw-payload access remains governed by VS-00B.
Manual review records must be useful without dumping raw payload.
No customer-facing state may contradict verified payment existence.
```

---

## 13. Performance and Scaling Review

| Data / operation | Layer | Rule |
|---|---|---|
| PaymentAttempt state | Postgres durable | Use unique provider/reference and indexed order/status lookups. |
| PaymentEvent dedupe | Postgres + Redis warm dedupe | Unique DB index is durable; Redis avoids thundering herd. |
| Duplicate processing lock | Redis hot lock | Short TTL lock; DB state remains source of truth. |
| Expired late-payment inventory recovery | Redis hot ledger + Postgres durable state | Use ReservationLedger; fail closed if ledger unhealthy. |
| Manual-review lists | Postgres indexed reads / cached admin aggregates | No large scans during peak. |
| Telemetry counters | Redis/metrics backend | Store real-time counters outside hot transactional DB path. |

Performance gates:

```text
No payment worker may scan all PaymentEvents.
No payment worker may scan all Orders by buyer details.
No late-payment recovery may load full event/order histories into memory.
No Redis inventory keys may be mutated outside ReservationLedger.
No provider HTTP call may run inside a DB transaction.
No DB transaction may wrap slow external work.
Duplicate webhook bursts must collapse through dedupe/idempotency.
```

Target behavior:

```text
sub-100ms local duplicate classification after provider verification result is known
fast fail-closed behavior when Redis inventory ledger is unhealthy
no oversell under late-payment spikes
safe duplicate Oban execution forever
```

---

## 14. RED/GREEN Test Plan

### Group A — Duplicate handling

```text
RED: duplicate webhook after payment verified creates extra harmful transitions.
GREEN: duplicate webhook is idempotent and marks duplicate/no-op safely.

RED: duplicate VerifyPaymentWorker execution downgrades or reprocesses verified_success incorrectly.
GREEN: duplicate worker returns idempotent success and preserves durable truth.
```

### Group B — Amount/currency/reference mismatch

```text
RED: amount mismatch moves Order to paid_verified.
GREEN: amount mismatch moves PaymentAttempt/Order/PaymentEvent to manual_review with reason code.

RED: currency mismatch is silently normalized or ignored.
GREEN: currency mismatch moves to manual_review and no fulfillment is queued.

RED: reference mismatch updates the wrong Order by email/phone fallback.
GREEN: reference mismatch is unmatched/manual_review and no order becomes paid.
```

### Group C — Provider failed/pending/timeout

```text
RED: provider failed status issues a ticket or marks paid_verified.
GREEN: provider failed status marks failed/manual_review according to matrix.

RED: transient provider timeout permanently fails the order immediately.
GREEN: timeout retries safely and preserves existing state.
```

### Group D — Unmatched PaymentEvent

```text
RED: unmatched valid webhook is deleted or ignored completely.
GREEN: unmatched event is persisted, marked unmatched, and remains retryable/queryable.

RED: unmatched event creates a local order/payment attempt from provider payload.
GREEN: unmatched event does not create value-delivery state.
```

### Group E — Payment after expiry

```text
RED: verified payment after checkout expiry blindly issues tickets.
GREEN: no ticket issuance occurs in this slice.

RED: verified payment after expiry with unavailable inventory marks order fulfillment-ready.
GREEN: order/payment/checkout move to manual_review with late_payment_inventory_unavailable.

RED: Redis unavailable during late-payment inventory recovery is ignored.
GREEN: ledger-unhealthy case fails closed to manual_review.

RED: late-payment recovery mutates Redis keys directly.
GREEN: all late-payment inventory recovery goes through ReservationLedger public API.
```

### Group F — Policy and access

```text
RED: customer_session can trigger payment outcome transitions.
GREEN: only system/admin-approved paths can run outcome transitions.

RED: operator can view raw provider payload by default.
GREEN: operator sees sanitized summary only.
```

### Group G — Boundary creep

```text
RED: VS-07C creates TicketIssue rows.
GREEN: no TicketIssue creation/mutation exists.

RED: VS-07C creates or mutates Attendee rows.
GREEN: existing Attendee domain is untouched.

RED: VS-07C enqueues IssueTicketsWorker.
GREEN: no ticket issuance job is enqueued in this slice.

RED: VS-07C mutates scanner/mobile sync state.
GREEN: scanner/mobile sync remains untouched.

RED: VS-07C sends WhatsApp/Meta messages.
GREEN: no WhatsApp/Meta behavior exists.
```

### Group H — Logging/security

```text
RED: logs contain authorization_url, access_code, raw payload, phone, email, or token.
GREEN: logs contain only sanitized classifier metadata.
```

---

## 15. Acceptance Criteria

A coding agent may mark VS-07C complete only when:

```text
Payment outcome handler exists and is the single approved place for mismatch/failure/duplicate/expired-payment outcome decisions.
Duplicate webhook/payment/worker execution is idempotent.
Amount mismatch moves to manual_review and never paid_verified.
Currency mismatch moves to manual_review and never paid_verified.
Reference mismatch/unmatched event cannot update the wrong order.
Unmatched PaymentEvents are retained and retryable/queryable.
Expired checkout + verified payment follows payment-after-expiry policy.
Late-payment inventory recovery uses ReservationLedger only.
Redis/ledger unhealthy late payment fails closed into manual_review.
No tickets are issued.
No Attendees are created or mutated.
No scanner/mobile sync code changes are made.
No WhatsApp/Meta messages are sent.
Every meaningful state change records StateTransition.
Manual review reason codes are stable and non-empty.
Raw provider payloads, secrets, authorization URLs, access codes, phone/email, and tokens are not logged.
Policy tests prove customer_session cannot run payment outcome transitions and operator cannot view raw payloads by default.
All RED/GREEN tests are implemented and pass.
Final report lists exact files changed and confirms forbidden boundaries were not crossed.
```

---

## 16. Rollback and Recovery Notes

Rollback should be safe because this slice should avoid destructive migrations.

If a migration is unavoidable:

```text
Prefer additive nullable fields first.
Backfill only through explicit reviewed task.
Do not rewrite provider raw payloads.
Do not destroy unmatched events.
Do not collapse manual_review reasons into free text only.
```

Operational recovery:

```text
If Redis inventory ledger is unhealthy, late-payment recovery must be paused/fail-closed.
If Paystack verification is temporarily unavailable, workers retry; they do not mark paid or failed prematurely.
If mismatches spike, alert admin/support and keep orders out of fulfillment.
If unmatched events spike, keep them retained for reconciliation and investigate initialization/webhook timing.
```

---

## 17. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-07C payment failure, mismatch, duplicate, unmatched-event, and expired-checkout outcome handling for FastCheck Sales. |
| Objective | Protect money, inventory, and customer trust after Paystack verification by routing non-happy-path payment outcomes into safe idempotent states or audited manual review without issuing tickets. |
| Output | Add `lib/fastcheck/payments/paystack/payment_outcomes.ex`, `lib/fastcheck/payments/paystack/payment_outcome_handler.ex`, optional `lib/fastcheck/payments/paystack/payment_failure_reason.ex`, targeted updates to `lib/fastcheck/workers/verify_payment_worker.ex`, and tests under `test/fastcheck/payments/paystack/`. Final report must list all changed files and forbidden boundaries checked. |
| Note | Use named Ash actions only for `PaymentAttempt`, `PaymentEvent`, `Order`, `CheckoutSession`, and `StateTransition`. Do not use generic `update_status`. Do not call Paystack HTTP inside Ash actions. Do not issue tickets, create/mutate Attendees, enqueue ticket issuance, change scanner/mobile sync, create DeliveryAttempts, or send WhatsApp/Meta messages. Late-payment inventory recovery may use only `FastCheck.Sales.Inventory.ReservationLedger` public API. Required indexes: provider/reference unique index, payment_events processing_status/inserted_at, orders expires_at/status, checkout_sessions status/expires_at. Caching: invalidate admin payment/order dashboard cache on manual_review/failed/unmatched/duplicate outcomes; never cache raw payloads. TTL: payment dedupe/lock keys 24h+ for events, short 60s locks for active processing. Redis structure: SETNX-style dedupe/lock keys only; inventory recovery through ReservationLedger. Invalidation triggers: payment outcome state changes broadcast safe PubSub admin events only. PubSub: broadcast sanitized `payments:manual_review`, `payments:mismatch`, `payments:unmatched_event`, `payments:duplicate_ignored`, `payments:late_payment_recovered`, `payments:late_payment_manual_review`. Must be safe under duplicate Oban execution, webhook bursts, Redis outage, Paystack timeout, and expired checkout. No raw provider payloads, authorization URLs, access codes, phone/email, tokens, or secrets in logs. |

---

## 18. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales slice VS-07C — Payment Failure and Mismatch Handling.

Goal:
Implement the payment outcome layer after Paystack server-side verification exists. Handle duplicate webhooks/payments, amount mismatch, currency mismatch, reference mismatch, unmatched PaymentEvents, provider failed/pending outcomes, and expired checkout with verified payment. Keep the system safe, idempotent, auditable, and scanner-neutral.

Architecture rules:
- Ash domain: FastCheck.Sales.
- Touch only PaymentAttempt, PaymentEvent, Order, CheckoutSession, and StateTransition through named Ash actions.
- Prefer plain modules:
  - lib/fastcheck/payments/paystack/payment_outcomes.ex
  - lib/fastcheck/payments/paystack/payment_outcome_handler.ex
  - lib/fastcheck/payments/paystack/payment_failure_reason.ex if useful
- Update VerifyPaymentWorker only to call the outcome handler where necessary.
- Use ReservationLedger only through its public API for late-payment inventory recovery.
- Do not mutate Redis inventory keys directly.
- Do not call Paystack HTTP from Ash resource actions.
- Do not use generic update_status actions or direct Repo status updates.

Required behavior:
- Duplicate webhook/payment/worker execution is idempotent forever.
- Amount mismatch -> manual_review / verified_amount_mismatch, no paid_verified, no ticket issue.
- Currency mismatch -> manual_review / verified_currency_mismatch, no paid_verified, no ticket issue.
- Reference mismatch -> unmatched/manual_review, never update the wrong order by email/phone fallback.
- Provider failed/abandoned/pending -> failed/manual_review/retryable according to state matrix.
- Unmatched PaymentEvent -> retained, marked unmatched, retryable/queryable; never deleted or used to create an order.
- Verified payment after checkout expiry follows payment-after-expiry policy:
  - if inventory can be safely recovered through ReservationLedger, move to safe paid/fulfillment-ready state but do not issue tickets;
  - if inventory unavailable or ledger unhealthy, move to manual_review;
  - no customer-facing state may say no payment exists after verified payment exists.
- Every meaningful transition records StateTransition with sanitized metadata.
- Manual review reason code is required.

Forbidden:
- No TicketIssue creation/mutation.
- No Attendee creation/mutation.
- No IssueTicketsWorker enqueue.
- No scanner/mobile sync changes.
- No DeliveryAttempt creation.
- No WhatsApp/Meta behavior.
- No provider refund API.
- No raw payload, authorization_url, access_code, phone/email, token, or secret logging.

Tests:
Add RED/GREEN tests for duplicate handling, amount mismatch, currency mismatch, reference mismatch, provider failed/pending/timeout, unmatched PaymentEvent, expired checkout + verified payment, Redis unavailable late-payment recovery, actor policies, operator raw-payload denial, and boundary creep.

Final report:
List changed files, tests run, state transitions added/used, reason codes added, Redis/cache/PubSub impact, and explicit confirmation that tickets, attendees, scanner/mobile sync, DeliveryAttempt, and WhatsApp were not touched.
```

---

## 19. Human Review Checklist

Before approving the VS-07C implementation, verify:

```text
[ ] Outcome handler is centralized and not scattered across controllers/workers/resources.
[ ] Duplicate payment/webhook execution is idempotent.
[ ] Amount mismatch cannot mark order paid_verified.
[ ] Currency mismatch cannot mark order paid_verified.
[ ] Reference mismatch cannot update wrong order.
[ ] Unmatched PaymentEvents are retained and retryable/queryable.
[ ] Expired checkout + verified payment follows policy and fails closed when inventory is unavailable/unhealthy.
[ ] Late-payment inventory recovery uses ReservationLedger only.
[ ] No Paystack HTTP call is inside Ash resource actions.
[ ] No direct Redis key mutation was added outside ReservationLedger.
[ ] No direct Repo status update bypasses Ash actions.
[ ] No TicketIssue is created or mutated.
[ ] No Attendee is created or mutated.
[ ] No scanner/mobile sync changes were made.
[ ] No IssueTicketsWorker enqueue was added.
[ ] No DeliveryAttempt or WhatsApp behavior was added.
[ ] Manual review reason codes are stable and required.
[ ] StateTransition rows are appended for all meaningful state changes.
[ ] Raw payloads/secrets/PII/tokens are not logged.
[ ] Operator raw payload access is denied by default.
[ ] Tests prove all major success/failure/idempotency/security/boundary cases.
```

---

## 20. Next Slice

```text
VS-08 — Ticket Code, QR, and Delivery Token Foundation
```

VS-08 may proceed in parallel with some payment work only if it stays strictly in token/QR foundation and does not issue tickets. VS-09A must wait for VS-07C, VS-02, and VS-08.
