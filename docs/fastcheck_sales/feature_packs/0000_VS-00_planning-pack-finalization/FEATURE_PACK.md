# FastCheck Sales Feature Planning Pack — VS-00 Planning Pack Finalization

**Pack ID:** `0000_VS-00_planning-pack-finalization`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0000_VS-00_planning-pack-finalization/`  
**Slice:** `VS-00`  
**Slice name:** Planning Pack Finalization  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Ready for planning, not implementation  
**Primary area:** Docs / Architecture  
**Depends on:** None  
**Blocks:** VS-00A, VS-00B, VS-00C, VS-00D, VS-01A+  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack finalizes the source-of-truth planning layer before any dangerous implementation begins.

The output of this slice is not application code. The output is an accepted planning baseline that coding agents can safely build from.

The core product direction must be preserved:

```text
FastCheck Sales is multi-channel, but WhatsApp is first.

Primary production customer channel:
  WhatsApp via Meta Cloud API

Payment provider:
  Paystack

Durable Sales state:
  Ash/Postgres

Hot inventory and active sessions:
  Redis

Scanner validity:
  Existing FastCheck attendee/scanner path

Secondary supported Sales paths:
  admin-assisted sales
  web checkout sales
  internal pilot sales
```

---

## 2. Ultimate Outcome

After VS-00 is complete, the project has a clean, accepted planning foundation:

```text
architecture docs accepted
roadmap docs accepted
risk register created
decision log created
blocking questions listed
implementation boundaries confirmed
slice chain confirmed
primary WhatsApp-first strategy confirmed
secondary channel policy confirmed
```

No code should be written in this slice.

---

## 3. Scope

### In scope

```text
Review and finalize the two hardened planning documents.
Create a decision log for unresolved architecture/product decisions.
Create a risk register for the Sales roadmap.
Confirm the multi-channel but WhatsApp-first strategy.
Confirm implementation boundaries.
Confirm the slice dependency chain.
Confirm what VS-00A, VS-00B, VS-00C, and VS-00D must produce.
Mark all implementation slices blocked until their gates are accepted.
```

### Out of scope

```text
No Elixir code.
No Ash resource modules.
No migrations.
No Redis scripts.
No Paystack client implementation.
No Meta API implementation.
No Oban workers.
No LiveView/admin UI.
No scanner changes.
No test code beyond documentation validation notes.
```

---

## 4. Domain and Ash Details

### Ash domain

```text
FastCheck.Sales
```

### Ash resources involved in this slice

No Ash resources are created or modified in VS-00.

VS-00 only confirms that future slices will use these planned resources:

```text
FastCheck.Sales.TicketOffer
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.PaymentEvent
FastCheck.Sales.TicketIssue
FastCheck.Sales.DeliveryAttempt
FastCheck.Sales.Conversation
FastCheck.Sales.StateTransition
```

### Non-Ash boundaries to preserve

VS-00 must explicitly preserve these boundaries:

```text
Paystack HTTP calls stay outside Ash resources.
Meta Cloud API calls stay outside Ash resources.
Redis Lua and Redis mutation stay outside Ash resources.
Ticket issuance orchestration stays in FastCheck.Tickets.Issuer.
Existing Attendees, Events, Tickera sync, Android API, and scanner hot path are not migrated to Ash.
WhatsApp is an interface layer, not the payment authority, inventory authority, or ticket authority.
```

---

## 5. Required Decisions to Capture

Create or update a decision log with these entries.

| Decision | Required VS-00 outcome |
|---|---|
| Primary channel | Confirm WhatsApp-first production sales channel. |
| Secondary channels | Confirm admin-assisted and web checkout are supported secondary Sales paths. |
| Internal pilot | Confirm whether internal pilot is allowed before public sales. |
| Launch scope vocabulary | Confirm accepted launch scopes: `whatsapp_first_paid_core`, `admin_assisted_sales`, `web_checkout_sales`, `internal_pilot_sales`. |
| Tenant model | Record whether first release is single-tenant or future multi-tenant. Defer implementation to VS-00B/VS-01 if unresolved. |
| Source docs | Confirm exact current source docs and versions. |
| Implementation block gates | Confirm VS-01A+ cannot start until VS-00A, VS-00B, VS-00C, and VS-00D are accepted. |
| Web checkout priority | Confirm web checkout is secondary and must use same Sales core. |
| Admin-assisted priority | Confirm admin-assisted checkout is allowed but must not bypass inventory/payment/ticket rules. |

---

## 6. Risk Register Seed

Create a risk register with at least these entries.

| Risk | Severity | Required handling |
|---|---:|---|
| WhatsApp becomes business-logic owner | P0 | WhatsApp must call Sales/Checkout services only. |
| Web/admin checkout bypasses Redis inventory | P0 | Every channel must use ReservationLedger. |
| Payment webhook treated as payment authority | P0 | Paystack server-side verification required. |
| Ticket issued before verified payment | P0 | Issuance depends on verified payment and legal transition matrix. |
| Duplicate worker creates duplicate tickets | P0 | Issuance idempotency required in VS-09A–VS-09D. |
| Redis loss causes oversell | P0 | Redis recovery contract required in VS-00C. |
| Refunded ticket still scans | P0 | VS-15A required before paid launch. |
| Raw provider payload leaks PII | P0 | VS-00B required before provider ingestion. |
| Agents start VS-01A before gates | P0 | Roadmap/Kanban must mark implementation blocked. |
| Launch scope unclear | P0 | VS-00D must confirm channel priority and launch scope. |

---

## 7. Required Files / Artifacts

The coding agent should create or update planning artifacts only.

Recommended repo paths:

```text
docs/fastcheck_sales/docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
docs/fastcheck_sales/decisions/DECISION_LOG.md
docs/fastcheck_sales/risks/RISK_REGISTER.md
docs/fastcheck_sales/slices/VS-00_PLANNING_PACK_FINALIZATION.md
docs/fastcheck_sales/README.md
```

If the repo already has a different docs folder convention, follow the existing convention but keep names explicit and searchable.

---

## 8. RED / GREEN Documentation Tests

These are not app tests. They are documentation validation checks that must fail before the planning docs are complete and pass after VS-00 is done.

### RED checks

The planning pack is not accepted while any of these are true:

```text
No explicit statement that WhatsApp is the first/primary production sales channel.
No explicit statement that web/admin paths are supported secondary Sales paths.
No explicit statement that all channels use the same Sales core.
No decision log exists.
No risk register exists.
No implementation-blocking gate exists for VS-01A+.
No statement that WhatsApp cannot own payment, inventory, ticket issuance, or scanner validity.
No statement that Paystack webhook is not payment authority.
No statement that Redis inventory contract must precede checkout implementation.
No statement that VS-15A scanner-safe revocation is required before paid launch.
```

### GREEN checks

The planning pack is accepted only when all of these pass:

```text
The roadmap names WhatsApp as primary production channel.
The roadmap allows secondary web/admin sales paths without making them default.
The Ash Atlas states WhatsApp, web, and admin channels must all use the same Sales core.
DECISION_LOG.md exists and records all VS-00 decisions.
RISK_REGISTER.md exists and includes P0 architecture risks.
VS-00A, VS-00B, VS-00C, and VS-00D are clearly marked as required gates.
VS-01A+ implementation slices are blocked until required gates are accepted.
No source doc implies WhatsApp owns payment, inventory, issuance, or scanner validity.
No source doc implies web/admin checkout may bypass Redis inventory or Paystack verification.
```

Optional command-style checks the agent may use:

```bash
grep -R "WhatsApp" docs/fastcheck_sales

grep -R "secondary" docs/fastcheck_sales

grep -R "VS-00A" docs/fastcheck_sales

grep -R "VS-01A" docs/fastcheck_sales

grep -R "ReservationLedger" docs/fastcheck_sales

grep -R "Paystack" docs/fastcheck_sales
```

These grep checks are sanity checks only. Human review still decides acceptance.

---

## 9. Acceptance Criteria

VS-00 is complete when:

```text
Both hardened source docs are present and treated as source of truth.
Primary WhatsApp-first strategy is explicit.
Secondary web/admin sales paths are explicit and constrained.
No channel can bypass Redis inventory, Paystack verification, idempotent ticket issuance, DeliveryAttempt audit, or scanner-safe revocation.
Decision log exists.
Risk register exists.
Known blockers are documented.
VS-00A, VS-00B, VS-00C, and VS-00D outputs are clearly defined.
VS-01A+ remains blocked until the relevant gate slices are accepted.
No implementation code was added.
```

---

## 10. Coding-Agent TOON Prompt

| Field | Content |
|---|---|
| Task | Finalize the VS-00 planning pack for FastCheck Sales. |
| Objective | Establish a safe source-of-truth planning baseline before implementation. Confirm that FastCheck Sales is multi-channel with WhatsApp first, and that all sales channels use the same backend Sales core. |
| Output | Updated planning docs if needed, `docs/fastcheck_sales/decisions/DECISION_LOG.md`, `docs/fastcheck_sales/risks/RISK_REGISTER.md`, and `docs/fastcheck_sales/slices/VS-00_PLANNING_PACK_FINALIZATION.md`. |
| Note | Do not write application code. Do not create Ash resources, migrations, Redis scripts, Paystack clients, Meta clients, workers, or UI. Preserve the boundary that WhatsApp, web, and admin entrypoints are interfaces only. No channel may bypass Redis inventory reservation, Paystack server-side verification, idempotent ticket issuance, DeliveryAttempt audit, or scanner-safe revocation. Mark VS-01A+ implementation blocked until VS-00A, VS-00B, VS-00C, and VS-00D are accepted. |

---

## 11. Copy-Paste Prompt for Coding Agent

```text
You are working on FastCheck Sales, an Elixir Phoenix / Ash 3.x planning project.

Implement only the VS-00 Planning Pack Finalization slice.

Your job is documentation and planning only. Do not write application code, migrations, Ash resources, Redis scripts, Paystack code, Meta API code, Oban workers, LiveView UI, or scanner changes.

Use these source docs as the current planning baseline:
- docs/fastcheck_sales/docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
- docs/fastcheck_sales/docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md

Create or update:
- docs/fastcheck_sales/decisions/DECISION_LOG.md
- docs/fastcheck_sales/risks/RISK_REGISTER.md
- docs/fastcheck_sales/slices/VS-00_PLANNING_PACK_FINALIZATION.md
- docs/fastcheck_sales/README.md if needed

Required product framing:
- FastCheck Sales is multi-channel, but WhatsApp is first.
- Primary production customer channel is WhatsApp via Meta Cloud API.
- Paystack is the payment provider.
- Ash/Postgres owns durable Sales state.
- Redis owns hot inventory holds and active sessions.
- Existing FastCheck attendee/scanner path owns scanner validity.
- Admin-assisted sales and web checkout sales are allowed secondary channels.
- Internal pilot sales are allowed for testing if explicitly marked as non-public launch scope.

Required architecture boundaries:
- WhatsApp must not own payment authority, inventory authority, ticket issuance, or scanner validity.
- Web/admin sales paths must not bypass the shared Sales core.
- Every channel must use Redis ReservationLedger for inventory.
- Every paid order must use Paystack server-side verification before ticket issuance.
- Every ticket issuance path must be idempotent.
- Every delivery path must create DeliveryAttempt audit records.
- Refund/revocation must become scanner-non-acceptable before paid launch.

Required planning gates:
- VS-00A must define state-machine and failure-policy contracts.
- VS-00B must define security, PII, and token-policy contracts.
- VS-00C must define Redis inventory recovery and reconciliation contracts.
- VS-00D must confirm WhatsApp-first production launch priority and selected secondary sales paths.
- VS-01A and all implementation slices remain blocked until their relevant gates are accepted.

Acceptance criteria:
- Decision log exists and records the channel, launch-scope, tenant, source-doc, and blocking-gate decisions.
- Risk register exists and includes P0 risks around WhatsApp logic ownership, inventory bypass, webhook authority, duplicate issuance, Redis loss, revocation/scanner safety, PII leakage, and unclear launch scope.
- VS-00 slice doc exists and states what is in scope, out of scope, accepted, and still blocked.
- No implementation code is added.
```

---

## 12. Human Review Checklist

Before marking VS-00 done, confirm:

```text
The docs say “WhatsApp first” without forbidding web/admin secondary sales.
The docs do not allow web/admin sales to bypass the Sales core.
The docs keep Paystack verification backend-controlled.
The docs keep Redis inventory as the required hot reservation path.
The docs keep ticket issuance backend-controlled and idempotent.
The docs keep scanner validity in the existing FastCheck scanner/attendee path.
The docs make VS-00A/B/C/D mandatory before implementation.
The agent did not sneak in implementation code.
```

---

## 13. Success Definition

VS-00 succeeds when a future coding agent cannot reasonably misunderstand the product as:

```text
a generic web checkout product
WhatsApp-owned business logic
Paystack-webhook-authorized ticket issuance
admin-bypass checkout
scanner-unsafe refund/revocation
```

The correct understanding must be:

```text
FastCheck Sales is a multi-channel Sales core with WhatsApp-first production sales.
All channels use the same safe backend path for inventory, payment verification, ticket issuance, delivery audit, and scanner validity.
```
