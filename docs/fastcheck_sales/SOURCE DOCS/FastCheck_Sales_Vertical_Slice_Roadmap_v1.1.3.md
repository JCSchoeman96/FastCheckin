# FastCheck Sales Platform — Vertical Slice Roadmap v1.1.3

**Source document:** `FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3.md`  
**Aligned architecture atlas:** `FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3.md`  
**Purpose:** Hardened vertical slice breakdown for coding-agent execution.  
**Constraint:** Each slice should be small enough to fit comfortably inside a single coding-agent run, targeting **less than 200k tokens of working context**.  
**Style:** High-level execution roadmap only. Do not expand these into detailed TOON prompts yet.  
**Version:** v1.1.3 HARDENED  
**Date:** 2026-06-12  
**Patch scope:** Roadmap document only. Clarifies multi-channel Sales strategy: WhatsApp-first as the primary production sales channel, with web/admin sales allowed as secondary paths.  

---

## 0. Roadmap Readiness Status

This roadmap is **not implementation-ready** until the planning-hardening slices are accepted.

Implementation is blocked for the dangerous core slices until the required contracts exist:

```text
VS-01A through VS-01G   # Ash/Sales data foundation
VS-04A through VS-04C   # Redis inventory ledger and recovery
VS-05                  # order and checkout core
VS-06B through VS-06C   # Paystack transaction initialization and tests
VS-07A through VS-07C   # Paystack webhook and verification
VS-09A through VS-09D   # ticket issuance and attendee bridge
VS-15A through VS-15B   # refund/revocation scanner visibility and admin operations
```

Allowed before hardening is complete:

```text
documentation
risk register work
credential checklist work
isolated provider-boundary research
runbook drafts
planning-card preparation
```

Do not let a coding agent begin database, state-machine, Redis, Paystack transaction integration, or ticket-issuance implementation until the relevant readiness gates are done.

---

## 0.1 Hardening Principles

This roadmap is designed around the following safety assumptions:

1. Payment systems fail in messy ways.
2. Webhooks duplicate, arrive late, or arrive before local state is ready.
3. Redis can restart or become temporarily unavailable.
4. Coding agents will invent missing rules unless the rules are explicit.
5. Scanner-visible behavior must remain stable and carefully reviewed.
6. Ticket issuance must be safe under retries forever.
7. Admin overrides are dangerous unless audited and constrained.
8. Observability and log-redaction rules must start early, not after launch.
9. Refund/revocation behavior is MVP-critical for paid events.
10. WhatsApp is an interface layer; payment integrity and scanner-safe ticket issuance come first.
11. Launch scope must be explicit. WhatsApp must not accidentally become mandatory for a non-WhatsApp launch.
12. Provider client boundaries may be built early, but transaction behavior must wait for checkout/order contracts.
13. The intended production product is multi-channel ticket sales with WhatsApp first through Meta Cloud API and Paystack payment.
14. Secondary non-WhatsApp entrypoints are secondary paths, not the default long-term customer channel.

---

## 0.2 Strategic Product Direction

FastCheck Sales is **not primarily a generic web checkout product**.

The intended production sales channel is:

```text
WhatsApp customer conversation
  -> Meta Cloud API inbound/outbound messaging
  -> FastCheck Sales checkout services
  -> Paystack backend transaction initialization
  -> Paystack webhook + server-side verification
  -> idempotent FastCheck ticket issuance
  -> secure ticket link / QR delivery
  -> existing FastCheck scanner acceptance
```

Build the Sales core first so that WhatsApp remains an interface layer only.

Required strategic rules:

```text
WhatsApp is the customer interface, not the source of truth.
Paystack is the payment provider, not the ticket authority.
Redis owns hot inventory holds, not WhatsApp.
Ash/Postgres owns durable Sales state, not WhatsApp.
FastCheck ticket issuance and scanner validity remain backend-controlled.
```

Secondary Sales path entrypoints are allowed for build/testing:

```text
internal pilot
admin-assisted checkout links
limited web checkout if deliberately approved
```

These secondary Sales path scopes do not change the intended product launch direction:

```text
whatsapp_first_paid_core
```

No true production launch should be treated as complete until the WhatsApp sales flow, Paystack payment flow, delivery handling, and operational runbooks are complete.

---

## 1. Slicing Rules

Use these rules when assigning work to agents:

1. One slice must have one dominant outcome.
2. One slice must avoid touching too many architectural layers at once.
3. Slices that modify the same migrations, schemas, indexes, or state machines must not run in parallel.
4. External provider integrations must stay behind boundaries and can often be developed in parallel once DB contracts are stable.
5. Scanner hot-path changes must be isolated and reviewed carefully.
6. Redis atomic inventory work is a core concurrency slice, not optional hardening.
7. WhatsApp is the intended production customer interface, but payment integrity and ticket issuance come first.
8. Every state-changing slice must include allow/deny transition tests.
9. Every worker or webhook slice must be idempotent by design.
10. Every customer-facing token slice must include hashing, expiry, revocation, and log-redaction checks.
11. A slice that defines a provider client must not also define checkout/payment business transitions unless explicitly scoped to do so.
12. Core scanner-safe revocation must not depend on admin UI implementation.
13. Non-WhatsApp entrypoints must be labelled as secondary Sales path scopes, not the first/primary production channel.
14. The WhatsApp-first primary launch must include Meta API inbound/outbound, conversation flow, Paystack link handoff, ticket delivery, and runbooks; web/admin sales remain secondary paths over the same Sales core.

---

## 1.1 Definition of Done for Every Slice

A slice is not Done unless it includes:

1. Clear acceptance criteria.
2. Explicit out-of-scope list.
3. Tests for the success path.
4. Tests for at least one realistic failure path.
5. Policy/permission tests where relevant.
6. Migration/index verification where relevant.
7. Idempotency tests for workers, webhooks, or external-event handling.
8. Confirmation that no forbidden cross-boundary calls were added.
9. Documentation of new states, actions, telemetry names, or worker queues.
10. Confirmation that scanner hot path was not accidentally modified unless the slice explicitly owns scanner behavior.
11. Confirmation that PII, raw provider payloads, access codes, authorization URLs, and plaintext tokens are not logged.
12. Confirmation that Redis/cache invalidation rules are documented when cache-facing behavior changes.
13. Confirmation that launch-scope assumptions are documented when a slice is conditional.

---

## 1.2 Forbidden Shortcuts

Coding agents must not implement these shortcuts:

```text
generic update_status actions
Paystack HTTP calls inside Ash resource actions
Meta/WhatsApp HTTP calls inside Ash resource actions
Redis Lua or Redis mutation inside Ash resources
Attendee creation hidden inside Sales.Order actions
ticket issuance directly from webhook controllers
payment verification based only on webhook payload
admin manual overrides without StateTransition audit reasons
plaintext storage of customer-facing ticket delivery tokens
operator access to raw provider payloads by default
paid-ticket launch without refund/revocation scanner behavior
WhatsApp-first checkout hidden inside secondary-channel VS-05A
scanner-safe revocation dependent on admin UI only
```

---

## 2. Recommended Vertical Slice Roadmap

| Slice | Name | Goal | Primary Area | Depends On | Parallelizable? |
|---:|---|---|---|---|---|
| VS-00 | Planning Pack Finalization | Finalize docs, decisions, risk register, and implementation boundaries. | Docs / Architecture | None | Yes |
| VS-00A | State Machine and Failure Policy Finalization | Define legal transitions, terminal states, payment-after-expiry, partial issuance, and manual review rules. | Docs / Architecture / QA | VS-00 | No |
| VS-00B | Security, PII, and Token Policy Finalization | Define PII masking, raw payload access, log redaction, delivery token hashing, expiry, and revocation rules. | Security / Docs | VS-00 | Yes |
| VS-00C | Inventory Recovery and Reconciliation Contract | Define Redis key structures, reserve/consume/release behavior, TTLs, restart recovery, and reconciliation rules. | Redis / Architecture | VS-00, VS-00A | No |
| VS-00D | Primary Channel and Multi-Channel Scope Decision | Confirm WhatsApp-first paid core as the primary production launch channel and select any secondary Sales paths for the release. | Product / Architecture | VS-00 | No |
| VS-01A | Ash Installation and Sales Domain Shell | Add Ash 3.x, AshPostgres, Sales domain module, config registration, and boundary docs. | Ash / Config | VS-00A, VS-00B, VS-00C, VS-00D | No |
| VS-01B | Core Sales Resource Skeletons | Add TicketOffer, Order, OrderLine, and StateTransition skeletons with migrations and basic reads. | Ash / DB | VS-01A | No |
| VS-01C | Checkout and Payment Resource Skeletons | Add CheckoutSession, PaymentAttempt, and PaymentEvent skeletons with indexes and identities. | Ash / DB | VS-01B | No |
| VS-01D | Ticket and Delivery Resource Skeletons | Add TicketIssue and DeliveryAttempt skeletons with corrected line-item sequence model and delivery ownership rules. | Ash / DB | VS-01C | No |
| VS-01E | Conversation Resource Skeleton | Add Conversation skeleton and durable WhatsApp checkpoint fields. | Ash / DB | VS-01C | Yes, reviewed with DB/Ash lead |
| VS-01F | Ash Policy Foundation | Add actor model, field restrictions, and policy tests for system/admin/operator/customer_session. | Ash / Security | VS-01B, VS-01C, VS-01D, VS-01E | No |
| VS-01G | Index and Migration Verification | Verify all identities, constraints, partial indexes, and query-path indexes. | DB / QA | VS-01B, VS-01C, VS-01D, VS-01E | No |
| VS-02 | Attendee Origin Protection | Protect FastCheck-sales attendees from Tickera reconciliation and define Sales-created attendee markers. | Existing Attendees / Sync | VS-01D | No |
| VS-03 | Ticket Offer Management | Add admin-manageable ticket offers for events with cache invalidation contracts. | Sales / Admin | VS-01B, VS-01F | Yes, after VS-01B/VS-01F |
| VS-04A | Inventory Ledger Contract Finalization | Define Redis operations, key structures, Lua contracts, TTLs, idempotency, and recovery rules. | Redis / Architecture | VS-00C, VS-03 | No |
| VS-04B | Atomic Inventory Ledger Implementation | Implement reserve, consume, release, expire, and availability operations with concurrency tests. | Redis / Concurrency | VS-04A | No |
| VS-04C | Inventory Reconciliation and Recovery | Add Redis/Postgres reconciliation tooling and restart/failure recovery tests. | Redis / Oban / QA | VS-04B, VS-05 | No |
| VS-05 | Order and Checkout Core | Add order/checkout state machines, create checkout sessions through Redis holds, enforce expiry hooks, and prepare payment-after-expiry outcomes. | Sales / Checkout | VS-01C, VS-03, VS-04B | No |
| VS-05A | Secondary Sales Entry Points | Implement selected secondary Sales paths: internal pilot, admin-assisted checkout links, and/or web checkout, all using the shared Sales core. | Web / Admin / Checkout | VS-00D, VS-05 | No |
| VS-06A | Paystack Client Boundary | Create Paystack config/client/verifier boundary modules with safe logging and no checkout integration. | Payments / Paystack | VS-00B | Yes |
| VS-06B | Paystack Transaction Initialization | Initialize backend Paystack transactions for valid checkout/order state. | Payments / Checkout | VS-05, VS-06A | No |
| VS-06C | Paystack Initialization Tests | Add idempotency, config, provider-failure, and no-secret-logging tests for initialization. | Payments / QA | VS-06B | No |
| VS-07A | Paystack Webhook Ingestion | Verify webhook signatures, persist raw events safely, dedupe, enqueue worker, and return quickly. | Payments / Webhook | VS-06B, VS-00B | No |
| VS-07B | Paystack Transaction Verification | Verify transactions server-side and apply amount, currency, status, and reference checks. | Payments / Verification | VS-07A | No |
| VS-07C | Payment Failure and Mismatch Handling | Handle duplicate, amount mismatch, currency mismatch, unmatched event, expired checkout, and manual-review transitions. | Payments / State | VS-07B, VS-05 | No |
| VS-08 | Ticket Code, QR, and Delivery Token Foundation | Generate secure ticket codes, QR payloads, hashed delivery tokens, expiry, and revocation foundations. | Tickets / Security | VS-01D, VS-00B | Yes |
| VS-09A | Ticket Issuance Contract and Idempotency Model | Define transaction/saga behavior, locks, uniqueness, and partial-failure rules. | Architecture / Tickets | VS-02, VS-07C, VS-08 | No |
| VS-09B | Attendee Creation Bridge | Create Sales-paid tickets as existing Attendee rows through the approved issuer service. | Tickets / Attendees | VS-09A | No |
| VS-09C | TicketIssue Audit Linking | Create TicketIssue rows linked to order lines and attendees using line_item_sequence. | Sales / Tickets | VS-09B | No |
| VS-09D | Issuance Retry and Partial Failure Tests | Prove duplicate workers, partial failure, retry safety, and partially issued order handling. | QA / Tickets | VS-09C | No |
| VS-10 | Event Sync Version Aggregator | Debounce/batch scanner-visible event sync version bumps. | Events / Mobile Sync / GenServer or Oban | VS-09D | Yes, but reviewed with VS-09A–VS-09D / Issuance owner |
| VS-11 | Secure Ticket Page | Add customer ticket page and QR display behind secure, hashed, expiring/revocable token flow. | Web / Tickets | VS-08, VS-09D | Yes |
| VS-12 | Admin Sales Dashboard | Add read-first dashboard for orders, payments, ticket issues, and status visibility with PII masking. | LiveView Admin | VS-01F, VS-07C, VS-09D | Yes, read-only shell first |
| VS-13 | Manual Review Operations | Add admin actions for resend, cancel, mark refunded, retry verification, and audited override. | LiveView Admin / Sales Ops | VS-12, VS-00A, VS-00B | No |
| VS-14 | Checkout Expiry and Cleanup | Expire abandoned holds/orders, release Redis inventory safely, reconcile Redis/Postgres state, and handle late payment hooks. | Oban / Redis / Sales | VS-04B, VS-05 | Yes, after VS-05 but before launch testing |
| VS-15A | Core Revocation and Scanner Visibility | Make cancelled/refunded/revoked tickets scanner-non-acceptable and sync-visible without relying on admin UI. | Sales / Attendees / Scanner Rules | VS-09D, VS-10 | No |
| VS-15B | Admin Refund and Revocation Operations | Add audited admin/manual refund and revocation actions using the core revocation path. | LiveView Admin / Sales Ops | VS-13, VS-15A | No |
| VS-16 | Meta Cloud API Outbound Client | Add direct Meta Cloud API message client and localized message builder behind provider boundary. | WhatsApp / Meta API | VS-00B | Yes |
| VS-17 | Meta Inbound Webhook and Session State | Add WhatsApp webhook, verification, Redis session state, dedupe, and rate limiting. | WhatsApp / Redis | VS-16, VS-00B | Yes |
| VS-18 | WhatsApp Number-Only Conversation Flow | Add Afrikaans-first number-only menus, slash-command shortcuts, and durable checkpoint recovery. | WhatsApp / UX State Machine | VS-17, VS-05 | Yes, after checkout contracts |
| VS-19 | WhatsApp Payment and Ticket Flow | Connect conversation to checkout, Paystack link, payment-pending messages, secure ticket page, and resend flow. | WhatsApp / Sales / Tickets | VS-07C, VS-11, VS-18 | No |
| VS-20 | WhatsApp Delivery Window Handling | Support Meta 24-hour window logic, utility templates, email fallback, and manual review on delivery failure. | WhatsApp / Delivery | VS-16, VS-11, VS-19 | Yes, after VS-16 |
| VS-21A | Observability Naming and Log Redaction Foundation | Define telemetry names, correlation IDs, non-PII logging, and baseline audit conventions. | Observability / Security | VS-00 | Yes; acceptance requires VS-00B alignment |
| VS-21B | Operational Metrics and Audit Views | Add counters, dashboards, Sentry context, audit views, and operational metrics. | Observability / Admin | VS-07C, VS-09D, VS-12 | Yes |
| VS-22 | End-to-End Sandbox Tests | Add full-path tests for the selected launch scope: payment, duplicate webhooks, expired checkout, ticket issue, scanner acceptance, revocation, delivery failure, and optional WhatsApp flows. | QA / Tests | Selected launch scope | No |
| VS-23A | Launch Runbook Draft | Draft Paystack, event-day, incident, rollback, Redis recovery, and manual review runbooks. | Docs / Ops | VS-00, VS-00B, VS-00C | Yes |
| VS-23B | Final Core Launch Runbooks | Finalize launch runbooks for the selected core paid-ticket launch scope. | Docs / Ops | VS-12, VS-15A, VS-22 | No |
| VS-23C | Final WhatsApp Launch Runbooks | Finalize Meta/WhatsApp delivery, template, fallback, and inbound incident runbooks. | Docs / Ops | VS-20, VS-22 | Only if WhatsApp is in launch scope |

---

## 2.1 Primary Channel and Multi-Channel Sales Options

VS-00D must select two things before VS-01A starts:

1. the primary production sales channel; and
2. any secondary Sales paths included in the release.

Primary production sales channel:

```text
whatsapp_first_paid_core
```

Supported secondary Sales paths:

| Sales path | Meaning | Required roadmap effect |
|---|---|---|
| Internal pilot sales | Only admin/test-created orders are allowed. | Used to prove Sales, Paystack, issuance, scanner sync, and admin operations before public traffic. |
| Admin-assisted sales | Operators create checkout links/orders for customers. | VS-05A includes admin checkout-link creation. Valid as a controlled secondary channel. |
| Web checkout sales | Public/customer-facing web checkout creates checkout sessions. | VS-05A includes public web checkout as a secondary channel after the shared Sales core is stable. |

Primary production launch scope:

| Launch scope | Meaning | Required roadmap effect |
|---|---|---|
| WhatsApp-first paid core | WhatsApp inbound/outbound, number-only conversation flow, Paystack link handoff, payment-pending handling, ticket resend, delivery handling, and runbooks are part of the first production launch. | VS-16, VS-17, VS-18, VS-19, VS-20, and VS-23C are production-launch-critical. |

No payment integration is launch-ready until the selected primary or secondary entrypoint is implemented and tested.

VS-05A must not pretend to implement WhatsApp-first checkout by itself. The real WhatsApp entrypoint is implemented by:

```text
VS-17 Meta Inbound Webhook and Session State
VS-18 WhatsApp Number-Only Conversation Flow
VS-19 WhatsApp Payment and Ticket Flow
```

Web/admin sales must be channel adapters over the same Sales core. They must not become separate business flows with separate inventory, payment, issuance, or revocation logic.

---

## 2.2 Selected Launch Scope

VS-00D must produce a selected launch scope and explicitly separate primary channel from secondary Sales paths.

Primary production launch scope:

```text
whatsapp_first_paid_core
```

Allowed secondary Sales path scopes:

```text
internal_pilot_sales
admin_assisted_sales
web_checkout_sales
```

Rules:

```text
whatsapp_first_paid_core is the first and primary production customer channel.
internal_pilot_sales cannot be used for public paid events.
admin_assisted_sales requires VS-05A admin checkout links and is valid as a controlled secondary channel.
web_checkout_sales requires VS-05A public web checkout and is valid as a secondary channel after the shared Sales core is stable.
whatsapp_first_paid_core requires VS-16, VS-17, VS-18, VS-19, VS-20, and VS-23C.
No secondary channel may bypass Redis inventory, Paystack verification, idempotent ticket issuance, DeliveryAttempt audit, or scanner-safe revocation.
```

The selected launch scope controls:

```text
VS-05A behavior
VS-16 through VS-20 required/blocked status
VS-22 required E2E tests
VS-23B / VS-23C runbook requirements
which secondary Sales channels are built before or after WhatsApp-first production launch
```

Strategic default:

```text
Primary production launch: whatsapp_first_paid_core
Secondary paths: admin_assisted_sales first, web_checkout_sales later unless explicitly pulled forward
```

A non-WhatsApp public paid launch must not become the default direction. Web/admin paths are valid secondary Sales paths, but WhatsApp is first.

---

## 3. Minimal Safe MVP Slice Set

The smallest safe Sales-core MVP depends on the selected primary launch scope and secondary Sales paths from VS-00D.

This MVP proves the backend Sales spine before or alongside channel rollout. The first true production customer channel remains WhatsApp-first; web/admin paths are valid secondary channels over the same Sales core.

Required for all Sales-core MVP modes:

| Required MVP Slice | Why |
|---|---|
| VS-00 | Locks architecture and boundaries. |
| VS-00A | Defines state transition and failure policy. |
| VS-00B | Defines security, PII, and token policy. |
| VS-00C | Defines inventory recovery and reconciliation. |
| VS-00D | Confirms WhatsApp-first as the primary production launch channel and selects secondary Sales paths. |
| VS-01A–VS-01G | Provides safe Ash/Sales data foundation. |
| VS-02 | Protects Sales-created attendees from Tickera reconciliation. |
| VS-03 | Defines sellable ticket offers. |
| VS-04A–VS-04C | Prevents overselling and supports inventory recovery. |
| VS-05 | Creates safe checkout sessions and order state transitions. |
| VS-05A | Provides selected secondary Sales paths such as admin-assisted sales, internal pilot sales, and/or web checkout sales. |
| VS-06A | Provides Paystack client/verifier boundary with safe logging. |
| VS-06B | Initializes Paystack transactions from backend for valid checkout/order state. |
| VS-06C | Proves Paystack initialization idempotency and failure handling. |
| VS-07A–VS-07C | Verifies payments and handles payment edge cases. |
| VS-08 | Creates ticket codes, QR payloads, and secure delivery-token foundation. |
| VS-09A–VS-09D | Issues scanner-compatible tickets exactly once. |
| VS-10 | Keeps scanner/mobile sync visible without event-row contention. |
| VS-11 | Provides secure customer ticket page. |
| VS-12 | Gives operators visibility. |
| VS-13 | Allows audited manual review operations. |
| VS-14 | Cleans up expired checkout/inventory state and reconciles Redis/Postgres. |
| VS-15A | Makes revoked/refunded/cancelled tickets scanner-non-acceptable and sync-visible. |
| VS-15B | Provides audited admin refund/revocation operations through the core revocation path. |
| VS-21A | Adds telemetry naming and log-redaction foundation. |
| VS-21B | Adds operational metrics and audit views for launch support. |
| VS-22 | Proves the full selected launch scope and critical failure paths. |
| VS-23A | Provides early draft runbooks. |
| VS-23B | Provides final core launch runbooks. |

For the first WhatsApp-first production launch, add these to the Sales-core MVP:

```text
VS-16
VS-17
VS-18
VS-19
VS-20
VS-23C
```

No real paid event launch is allowed unless VS-15A is complete. VS-15B is required if admin refund/revocation operations are part of launch. Launching without refunds, cancellations, or revocations after issue is technically possible but not recommended.

No first production customer launch is complete until the WhatsApp-first paid core slices are complete. Web/admin paths may also exist, but they are secondary channels and must use the same Sales core.

---

## 3.1 What Is Deliberately Not in the Early Sales-Core Validation Slice

These are not required for the earliest backend Sales-core validation slice, but WhatsApp remains required for the first primary production customer launch:

```text
full WhatsApp checkout during early Sales-core validation only if the team deliberately validates the core first
WhatsApp utility template fallback automation during early Sales-core validation
advanced analytics dashboards
multi-event campaign automation
bulk messaging
complex refund-provider automation
```

Do not confuse this with ignoring the foundations. Token security, revocation, inventory reconciliation, and scanner-visible refund/revoke behavior are still Sales-core MVP-critical.

Do not confuse secondary channels with the primary launch channel. The intended first production customer channel remains WhatsApp-first, while web/admin sales are valid secondary paths.

---

## 4. Suggested Kanban Board Columns

Use this board shape when creating the Kanban board:

| Column | Meaning |
|---|---|
| Backlog | Known slices not ready for implementation. |
| Ready | Slice has clear dependencies satisfied and acceptance criteria known. |
| In Progress | Currently assigned to an agent. |
| Review | Needs human/code review, architecture review, security review, or test review. |
| Blocked | Waiting on dependency, API credential, migration decision, architecture contract, launch-scope decision, or unresolved risk. |
| QA / Hardening | Built but needs concurrency, failure, integration, or load testing. |
| Done | Merged, tested, documented, reviewed, and safe to build on. |

Recommended swimlanes:

| Swimlane | Slices |
|---|---|
| Planning / Contracts | VS-00, VS-00A, VS-00B, VS-00C, VS-00D |
| Ash / DB Foundation | VS-01A, VS-01B, VS-01C, VS-01D, VS-01E, VS-01F, VS-01G |
| Core Sales | VS-03, VS-05, VS-05A |
| Inventory / Concurrency | VS-04A, VS-04B, VS-04C, VS-14 |
| Payments | VS-06A, VS-06B, VS-06C, VS-07A, VS-07B, VS-07C |
| Tickets / Scanner | VS-02, VS-08, VS-09A, VS-09B, VS-09C, VS-09D, VS-10, VS-11, VS-15A, VS-15B |
| WhatsApp / Meta | VS-16, VS-17, VS-18, VS-19, VS-20 |
| Admin / Ops | VS-12, VS-13, VS-21A, VS-21B, VS-23A, VS-23B, VS-23C |
| QA | VS-22 |

---

## 5. Parallelization Map

### Wave 0 — Hardening and decisions

Sequential or tightly reviewed:

```text
VS-00 -> VS-00A -> VS-00C -> VS-00D
```

Can run in parallel after VS-00 starts:

| Slice | Agent Type | Notes |
|---|---|---|
| VS-00B Security, PII, and Token Policy Finalization | Security/docs agent | Must finish before provider/raw-payload work is accepted. |
| VS-21A Observability Naming and Log Redaction Foundation | Observability/security agent | May start after VS-00; acceptance requires VS-00B alignment. |
| VS-23A Launch Runbook Draft | Ops/docs agent | Draft only; final core runbooks are VS-23B. |
| Meta/Paystack credential checklist | Ops agent | Do not place secrets in docs or commits. |

Do not start implementation before VS-00A, VS-00B, VS-00C, and VS-00D are accepted.

VS-23B and VS-23C are finalization slices and must not be accepted until VS-22 proves the selected launch scope.

---

### Wave 1 — Ash foundation

Recommended chain:

```text
VS-01A -> VS-01B -> VS-01C -> VS-01D -> VS-01G
```

Parallel after VS-01C, with lead review:

| Slice | Agent Type | Notes |
|---|---|---|
| VS-01E Conversation Resource Skeleton | DB/Ash agent | Avoid WhatsApp provider logic. |
| VS-08 Ticket Code/QR/Delivery Token Foundation | Ticketing/security agent | Must follow VS-00B token policy. |
| VS-16 Meta Cloud API Outbound Client | WhatsApp integration agent | Provider boundary only. |

Policy foundation should be reviewed before admin or customer-visible surfaces:

```text
VS-01F before VS-03, VS-12, VS-13, VS-05A public/admin checkout
```

---

### Wave 2 — Inventory and checkout

Recommended chain:

```text
VS-03 -> VS-04A -> VS-04B -> VS-05 -> VS-14 -> VS-04C
```

Notes:

1. VS-05 must consume the final VS-04B inventory API.
2. VS-05 must not invent direct Redis calls.
3. VS-14 should complete before real Paystack launch testing.
4. VS-04C validates recovery/reconciliation after checkout behavior exists.

Possible parallel work:

| Slice | Can Run While | Notes |
|---|---|---|
| VS-06A Paystack Client Boundary | VS-14 / VS-04C | Provider boundary can start early after VS-00B. |
| VS-06B Paystack Transaction Initialization | after VS-05 | Must wait for valid checkout/order contracts. |
| VS-12 Admin Dashboard read-only skeleton | VS-14 / VS-04C | Read-only shell only; no manual actions yet. |

Do not parallelize VS-04B and VS-05 heavily. Checkout correctness depends on the final Redis API.

---

### Wave 3 — Payments

Recommended chain:

```text
VS-06A -> VS-06B -> VS-06C -> VS-07A -> VS-07B -> VS-07C
```

Rules:

1. Webhook ingestion is not verification.
2. Verification must be server-side.
3. Amount, currency, provider status, and provider reference must match.
4. Payment-after-expiry behavior must follow VS-00A and VS-05.
5. Duplicate webhooks and duplicate verification workers must be safe.
6. VS-06A may start early, but VS-06B must wait for valid checkout/order contracts.

---

### Wave 4 — Issuance and scanner visibility

Recommended chain:

```text
VS-02 + VS-07C + VS-08 -> VS-09A -> VS-09B -> VS-09C -> VS-09D -> VS-10 -> VS-15A
```

Rules:

1. Do not let multiple agents modify ticket issuance and attendee mutation logic at the same time.
2. Only the approved issuer service may coordinate Ash Sales and existing Ecto Attendees.
3. Retry safety must be proven before VS-10 and VS-15A build on issuance behavior.
4. Scanner-visible revocation/refund behavior is not optional for a paid launch.
5. VS-15A must not depend on admin UI. It is a core safety slice.

---

### Wave 5 — Customer and admin surfaces

Parallel once foundations are stable:

| Slice | Depends On | Notes |
|---|---|---|
| VS-05A Secondary Sales Entry Points | VS-05, VS-00D | Must match the selected secondary Sales paths. It is not the WhatsApp production entrypoint. |
| VS-11 Secure Ticket Page | VS-08, VS-09D | Token security from VS-00B. |
| VS-12 Admin Sales Dashboard | VS-01F, VS-07C, VS-09D | Read-first; PII masked by default. |
| VS-13 Manual Review Operations | VS-12, VS-00A, VS-00B | Audited actions only. |
| VS-15B Admin Refund and Revocation Operations | VS-13, VS-15A | Must use the core revocation path. |

Do not add manual actions before the legal transition matrix and audit rules exist.

---

### Wave 6 — WhatsApp Production Layer

This track can follow the paid Sales core, but it is required for the intended production launch.

Recommended chain:

```text
VS-16 -> VS-17 -> VS-18 -> VS-19 -> VS-20 -> VS-23C
```

Rules:

1. WhatsApp must not become the payment authority.
2. WhatsApp conversation state must call approved Sales/checkout services.
3. WhatsApp must not issue tickets directly.
4. Payment-pending messages must not tell the customer that no ticket/payment exists when verified payment state is pending or delayed.
5. Meta 24-hour delivery-window behavior must be reflected in DeliveryAttempt records.
6. VS-20 and VS-23C are required for the intended WhatsApp-first production launch. They are not required only for a deliberately approved secondary sales path.

---

### Wave 7 — Final hardening

Mostly sequential:

```text
VS-21B -> VS-22 -> VS-23B
```

If WhatsApp is in launch scope:

```text
VS-20 -> VS-22 -> VS-23C
```

VS-22 should not start until the main happy path and critical failure paths exist for the selected launch scope.

VS-23A can begin as a draft in Wave 0, but final launch runbooks must not be accepted until VS-22 proves the system behavior.

---

## 6. Subagent Recommendations

Use subagents by domain, not by random file ownership.

| Subagent | Owns | Should Not Own |
|---|---|---|
| Architecture Lead | Slice sequencing, state-machine consistency, final reviews, cross-boundary decisions. | Writing all implementation. |
| Security/PII Agent | Token policy, raw payload restrictions, log redaction, admin/operator display rules. | Payment or ticket business logic. |
| DB/Ash Agent | Sales resources, migrations, indexes, identities, state transition persistence, Ash policies. | Redis Lua scripts or WhatsApp provider details. |
| Ecto/Scanner Agent | Attendee origin protection, sync reconciliation safety, scanner-visible behavior. | Paystack or Meta API work. |
| Redis/Concurrency Agent | Atomic inventory ledger, Lua scripts, hold expiry, Redis/Postgres reconciliation, rate limits. | Admin UI or Paystack HTTP client. |
| Payments Agent | Paystack client, initialization, webhook ingestion, transaction verification, payment states. | Ticket issuance internals. |
| Ticketing Agent | Ticket code generation, QR payload, delivery tokens, secure ticket page. | Payment verification. |
| Issuance Agent | Verified-order to attendee/ticket issue flow, idempotency, event sync bump integration. | WhatsApp menus. |
| WhatsApp Agent | Meta Cloud API, inbound/outbound messages, Afrikaans-first number-only menus. | Payment authority or ticket issuing. |
| Admin UI Agent | Sales dashboard, manual review tools, audit visibility, masked support views. | Core state-machine rules. |
| QA/Load Agent | E2E tests, duplicate webhook tests, concurrency tests, payment-after-expiry tests, load scenarios. | Feature implementation without review. |
| Ops Agent | Runbooks, checklists, incident playbooks, credentials checklist. | Runtime secrets themselves. |

---

## 7. Areas That Should Not Be Parallelized

Avoid parallel work on these unless there is a strong lead reviewer coordinating every merge:

| Area | Why |
|---|---|
| State transition matrices and Ash actions | Actions must implement the approved matrix, not invent transitions. |
| Sales migrations and Ash resources | Migration conflicts and state inconsistency risk. |
| TicketIssue sequence model and issuance idempotency | Mistakes create duplicate tickets. |
| Redis inventory ledger contract and checkout core | Checkout correctness depends on the final Redis API. |
| Atomic inventory ledger and checkout creation | Checkout must consume the final inventory ledger API. |
| Payment-after-expiry policy and Paystack verification | Late verified payments can oversell if policy is unclear. |
| Paystack transaction initialization and checkout state | Transaction initialization must not bypass checkout/order validity. |
| Payment verification and ticket issuance | Payment state must be stable before tickets issue. |
| Attendee origin protection and Tickera reconciliation | Mistakes can invalidate real tickets. |
| Event sync version bump behavior and ticket issuing | Scanner visibility depends on correct ordering. |
| Core revocation/scanner visibility and manual refund UI | Admin actions must use the core revocation path, not invent their own. |
| Manual review actions and core state machine | Admin override must not bypass safety rules accidentally. |
| PII policy and admin dashboard | Dashboard must not leak raw payloads or customer tokens. |
| WhatsApp-first scope and non-WhatsApp VS-05A | Do not hide WhatsApp dependencies inside a non-WhatsApp entrypoint slice. |

---

## 8. First Kanban Board Draft

### Ready

```text
VS-00 Planning Pack Finalization
VS-00B Security, PII, and Token Policy Finalization
VS-21A Observability Naming and Log Redaction Foundation — can start after VS-00; acceptance requires VS-00B alignment
VS-23A Launch Runbook Draft
Meta/Paystack credential checklist
```

### Blocked

```text
VS-00A — blocked until VS-00 accepted
VS-00C — blocked until VS-00/VS-00A alignment
VS-00D — blocked until architecture/product decision review; must confirm WhatsApp-first primary launch scope and selected secondary Sales paths
VS-01A — blocked until VS-00A, VS-00B, VS-00C, VS-00D
VS-01B — blocked until VS-01A
VS-01C — blocked until VS-01B
VS-01D — blocked until VS-01C
VS-01E — blocked until VS-01C
VS-01F — blocked until VS-01B, VS-01C, VS-01D, VS-01E
VS-01G — blocked until VS-01B, VS-01C, VS-01D, VS-01E
VS-02 — blocked until VS-01D
VS-03 — blocked until VS-01B and VS-01F
VS-04A — blocked until VS-00C and VS-03
VS-04B — blocked until VS-04A
VS-04C — blocked until VS-04B and VS-05
VS-05 — blocked until VS-01C, VS-03, VS-04B
VS-05A — blocked until VS-00D and VS-05; implements selected secondary Sales paths only
VS-06A — blocked until VS-00B
VS-06B — blocked until VS-05 and VS-06A
VS-06C — blocked until VS-06B
VS-07A — blocked until VS-06B and VS-00B
VS-07B — blocked until VS-07A
VS-07C — blocked until VS-07B and VS-05
VS-08 — blocked until VS-01D and VS-00B
VS-09A — blocked until VS-02, VS-07C, VS-08
VS-09B — blocked until VS-09A
VS-09C — blocked until VS-09B
VS-09D — blocked until VS-09C
VS-10 — blocked until VS-09D
VS-11 — blocked until VS-08 and VS-09D
VS-12 — blocked until VS-01F, VS-07C, VS-09D
VS-13 — blocked until VS-12, VS-00A, VS-00B
VS-14 — blocked until VS-04B and VS-05
VS-15A — blocked until VS-09D and VS-10
VS-15B — blocked until VS-13 and VS-15A
VS-16 — blocked until VS-00B
VS-17 — blocked until VS-16 and VS-00B
VS-18 — blocked until VS-17 and VS-05
VS-19 — blocked until VS-07C, VS-11, VS-18
VS-20 — blocked until VS-16, VS-11, VS-19
VS-21B — blocked until VS-07C, VS-09D, VS-12
VS-22 — blocked until selected launch scope exists
VS-23B final core runbooks — blocked until VS-12, VS-15A, and VS-22
VS-23C final WhatsApp runbooks — blocked until VS-20 and VS-22, only if WhatsApp is in launch scope
```

### Backlog

```text
All blocked items not yet dependency-ready.
```

### In Progress

```text
None yet
```

### Review

```text
None yet
```

### QA / Hardening

```text
None yet
```

### Done

```text
None yet
```

---

## 9. Recommended First Agent Assignments

### Assignment 1

```text
Slice: VS-00 Planning Pack Finalization
Agent: Architecture/documentation agent
Purpose: Lock final source-of-truth docs, boundary decisions, and risk register.
Output: Accepted architecture docs and explicit list of unresolved decisions.
```

### Assignment 2

```text
Slice: VS-00A State Machine and Failure Policy Finalization
Agent: Architecture + QA agent
Purpose: Define transition matrices before Ash resources/actions are implemented.
Output: Legal transition tables for Order, CheckoutSession, PaymentAttempt, PaymentEvent, TicketIssue, DeliveryAttempt, and Conversation.
```

### Assignment 3

```text
Slice: VS-00B Security, PII, and Token Policy Finalization
Agent: Security/docs agent
Purpose: Prevent unsafe raw payload, PII, and token handling from entering early slices.
Output: Field access rules, log-redaction rules, token hashing/expiry/revocation rules, admin/operator display rules.
```

### Assignment 4

```text
Slice: VS-00C Inventory Recovery and Reconciliation Contract
Agent: Redis/concurrency architect
Purpose: Define inventory behavior before checkout and Redis Lua are implemented.
Output: Redis key contract, operation contract, TTL strategy, recovery policy, reconciliation rules.
```

### Assignment 5

```text
Slice: VS-00D Primary Channel and Multi-Channel Scope Decision
Agent: Product/architecture lead
Purpose: Prevent building payment flows with unclear channel ownership while preserving WhatsApp-first production priority and allowing secondary web/admin sales paths.
Output: Confirmed whatsapp_first_paid_core primary launch scope, selected secondary Sales paths, VS-05A behavior, and required WhatsApp launch slices.
```

### Assignment 6

```text
Slice: VS-21A Observability Naming and Log Redaction Foundation
Agent: Observability/security agent
Purpose: Reserve telemetry/logging conventions early while aligning with security policy.
Output: Telemetry naming, correlation ID rules, log-redaction checklist, acceptance aligned with VS-00B.
```

### Assignment 7

```text
Slice: VS-23A Launch Runbook Draft
Agent: Ops/docs agent
Purpose: Start operational thinking early without pretending runbooks are final.
Output: Draft runbooks for Paystack, event day, Redis recovery, incident response, rollback, and manual review.
```

Do not assign VS-01A until Assignments 2–5 are accepted.

---

## 9.1 Standard Slice Card Template

Each slice/card must include:

```text
Slice ID:
Name:
Goal:
Primary files/areas:
Depends on:
Out of scope:
Actor/subagent:
Acceptance criteria:
Required tests:
State/action changes:
Indexes/migrations:
Redis/cache impact:
Oban/job impact:
Security/PII impact:
Scanner/mobile-sync impact:
Telemetry/logging impact:
Rollback/recovery notes:
Launch-scope impact:
Parallel safety:
```

---

## 9.2 Acceptance Criteria Standards by Slice Type

### Ash / DB slices

Must include:

```text
resource modules
migrations
identities
indexes
basic read/create tests where relevant
policy tests
migration rollback review
no external HTTP/Redis side effects inside Ash resources
```

### Redis / concurrency slices

Must include:

```text
atomic reserve/consume/release tests
idempotency tests
expiry tests
concurrency/load tests
Redis unavailable behavior
reconciliation behavior
no direct DB-heavy reads on hot path
```

### Payment slices

Must include:

```text
signature verification tests
webhook dedupe tests
server-side transaction verification tests
amount mismatch tests
currency mismatch tests
reference mismatch tests
duplicate webhook tests
late webhook/payment-after-expiry tests
raw payload access restrictions
no-secret/no-authorization-url logging tests
```

### Ticket issuance slices

Must include:

```text
idempotent retry tests
duplicate worker tests
partial failure tests
attendee origin marker tests
TicketIssue line_item_sequence tests
scanner-visible sync tests
no issuance from controllers/webhooks/LiveViews
```

### Revocation / scanner-visibility slices

Must include:

```text
revoked ticket scanner-deny tests
refunded ticket scanner-deny tests
cancelled ticket scanner-deny tests
event sync version bump tests
admin operation uses core revocation path
revocation audit reason tests
customer token invalidation tests
```

### Admin/manual review slices

Must include:

```text
actor policy tests
audit reason tests
PII masking tests
forbidden transition tests
operator vs admin permission tests
no raw payload leakage by default
```

### WhatsApp slices

Must include:

```text
webhook verification tests
message dedupe tests
rate-limit tests
Redis session recovery behavior
Afrikaans-first number-only flow tests
payment-pending customer-message tests
DeliveryAttempt tracking tests
```

### Runbook slices

Must include:

```text
incident trigger definitions
rollback decision points
manual review operating steps
Redis recovery procedure
payment-provider outage procedure
scanner/mobile-sync recovery procedure
launch go/no-go checklist
```

---

## 10. Recommended Next Step

Create or update the Kanban board from this hardened roadmap.

First cards to create:

```text
VS-00 Planning Pack Finalization
VS-00A State Machine and Failure Policy Finalization
VS-00B Security, PII, and Token Policy Finalization
VS-00C Inventory Recovery and Reconciliation Contract
VS-00D Primary Channel and Multi-Channel Scope Decision
VS-21A Observability Naming and Log Redaction Foundation
VS-23A Launch Runbook Draft
Meta/Paystack credential checklist
```

Do not expand every slice into full TOON prompts yet. First validate sequencing, dependencies, ownership, secondary Sales path scope, WhatsApp-first production launch scope, and blocking rules.

---

## 11. Final Roadmap Recommendation

This roadmap deliberately slows down the first implementation step.

That is intentional.

The original v1.0.1 roadmap had the right broad direction, but VS-01 was too large and the MVP missed several hard safety gates. The v1.1 version improved the slice model, v1.1.1 fixed dependency leaks, and v1.1.2 clarified WhatsApp-first intent. This v1.1.3 version adds the final strategic clarity: FastCheck Sales is multi-channel, but WhatsApp is the first and primary production sales channel through Meta Cloud API, with Paystack payment and FastCheck-controlled ticket issuance.

```text
state machines before Ash actions
PII/token policy before admin/provider surfaces
Redis recovery before checkout launch
Paystack client boundary before transaction initialization
Paystack verification before ticket issuance
ticket issuance idempotency before scanner visibility
core revocation before admin refund/revoke UI
revocation before paid event launch
observability/log redaction from the beginning
selected launch scope before E2E and final runbooks
WhatsApp launch requirements are mandatory for the intended production launch
```

The correct first implementation move is not VS-01A. The correct first move is to finish VS-00A, VS-00B, VS-00C, and VS-00D, then start VS-01A. VS-01A may only install/configure the Sales domain shell; resource and workflow implementation must wait for the relevant contracts.

The correct product direction is not generic web checkout. Build the Sales core first, then connect WhatsApp through Meta Cloud API as the production customer sales channel.
