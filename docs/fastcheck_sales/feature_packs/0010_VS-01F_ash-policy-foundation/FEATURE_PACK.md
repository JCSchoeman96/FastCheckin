# FastCheck Sales Feature Planning Pack — VS-01F Ash Policy Foundation

**Pack ID:** `0010_VS-01F_ash-policy-foundation`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0010_VS-01F_ash-policy-foundation`  
**Slice:** `VS-01F`  
**Slice name:** Ash Policy Foundation  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Ready for implementation only after VS-01B, VS-01C, VS-01D, VS-01E and planning gates are accepted  
**Primary area:** Ash / Security / Policies / Tests  
**Depends on:** VS-01B, VS-01C, VS-01D, VS-01E, VS-00A, VS-00B, VS-00C, VS-00D  
**Blocks:** VS-01G, VS-03, VS-05A, VS-12, VS-13, later customer/admin/provider surfaces  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack adds the first Ash policy foundation for the Sales domain.

It must protect the skeleton resources created in VS-01B through VS-01E:

```text
FastCheck.Sales.TicketOffer
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.StateTransition
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.PaymentEvent
FastCheck.Sales.TicketIssue
FastCheck.Sales.DeliveryAttempt
FastCheck.Sales.Conversation
```

This slice creates policy scaffolding and tests only. It must not add real checkout workflows, provider integrations, Redis mutation, ticket issuance, admin UI, WhatsApp flows, scanner changes, or broad customer access.

The strategic direction remains:

```text
FastCheck Sales is multi-channel, but WhatsApp is first.

Primary production customer channel:
  WhatsApp via Meta Cloud API

Secondary supported Sales paths:
  admin-assisted sales
  web checkout sales
  internal pilot sales

All channels must use the same Sales core.
No channel may bypass Redis inventory, Paystack verification, idempotent ticket issuance, DeliveryAttempt audit, or scanner-safe revocation.
```

---

## 2. Ultimate Outcome

After VS-01F is complete:

```text
The Sales resources have policy blocks or approved policy scaffolding.
The actor model is represented consistently across Sales resources.
System/admin/operator/customer_session behavior is tested.
Raw provider payload access is restricted.
PII/customer fields are protected from casual list/read exposure where Ash field policies are supported.
customer_session cannot broadly read or mutate Sales resources.
operator is not equivalent to admin.
Manual/system-only actions are not accidentally exposed.
No workflow implementation is added.
RED/GREEN tests prove the first policy boundary.
```

This pack does not need to produce perfect final authorization for every future action because many workflow actions do not exist yet. It must create the baseline policy shape that later slices must extend rather than bypass.

---

## 3. Scope

### In scope

```text
Inspect existing authentication/current-user/actor conventions.
Define the Sales actor shape used by Ash policies.
Add policy blocks or policy scaffolding to existing Sales skeleton resources.
Add tests for system/admin/operator/customer_session behavior.
Restrict raw provider payload fields to admin/system only.
Restrict customer_session broad reads and all direct mutations.
Ensure operator is read/support-oriented, not full admin.
Ensure StateTransition remains append-only from a policy perspective.
Document the policy extension rules for later workflow slices.
Run format, compile, and policy tests.
```

### Out of scope

```text
No checkout workflows.
No TicketOffer create/update/enable/disable workflows unless already skeleton-only and tested as unavailable to non-admins.
No Paystack HTTP client.
No Paystack webhook controller.
No payment verification logic.
No Redis reservation logic.
No QR rendering.
No ticket issuance orchestration.
No Attendee creation or scanner logic.
No DeliveryAttempt sending logic.
No Meta Cloud API client or webhook.
No WhatsApp conversation menu implementation.
No admin LiveView dashboard.
No manual review operations.
No new public/customer APIs.
No broad customer_session reads.
No generic update_status actions.
```

---

## 4. Required Pre-Implementation Decisions

The coding agent must read and follow the accepted outputs from VS-00A, VS-00B, VS-00C, VS-00D, VS-01A, VS-01B, VS-01C, VS-01D, and VS-01E.

### Actor model decision

Use the Sales actor model from the hardened atlas:

```text
system
admin
operator
customer_session
```

Required actor attributes:

```text
actor_type
actor_id or user_id where available
organization_id / allowed_event_ids if tenant/event isolation is accepted
support_scope where the existing app needs it
```

If the existing project already has auth/user roles, map them into this actor model rather than inventing a separate inconsistent role system.

### Tenant / organization decision

Follow the accepted tenant model.

Rules:

```text
If multi_tenant or future_multi_tenant_prepared is accepted:
  policies must include organization/event scoping where resources include organization_id/event_id.
  admin/operator list/read actions must not cross organization/event boundaries.

If single_tenant is accepted:
  document explicitly that tenant scoping is intentionally deferred.
  do not create fake tenant checks without fields to support them.

If no tenant decision exists:
  stop and report blocker.
```

### Security / PII / token decision

VS-00B is mandatory for this slice.

Rules:

```text
buyer_name, buyer_phone, buyer_email, phone_e164, wa_id, recipient, state_data, raw_payload, raw_initialize_response, raw_verify_response, authorization_url, access_code, delivery_token_hash, qr_token_hash, and provider identifiers must be treated according to VS-00B.
operator must not see raw provider payloads by default.
customer_session must never read raw provider payloads.
Logs must not include raw PII, access_code, authorization_url, provider payloads, or plaintext tokens.
```

### State-machine decision

VS-00A is mandatory for this slice.

Rules:

```text
Policy tests must prove customer_session/operator cannot call future state-changing actions directly unless explicitly allowed by a later slice.
No generic update_status action may be introduced.
StateTransition append-only policy must be prepared now.
```

---

## 5. Ash Domain and Resource Details

### Domain

```text
lib/fastcheck/sales.ex
FastCheck.Sales
```

The domain should expose resources but must not expose broad public/customer actions that bypass policies.

### Resources receiving policy foundation

```text
lib/fastcheck/sales/ticket_offer.ex
lib/fastcheck/sales/order.ex
lib/fastcheck/sales/order_line.ex
lib/fastcheck/sales/checkout_session.ex
lib/fastcheck/sales/payment_attempt.ex
lib/fastcheck/sales/payment_event.ex
lib/fastcheck/sales/ticket_issue.ex
lib/fastcheck/sales/delivery_attempt.ex
lib/fastcheck/sales/conversation.ex
lib/fastcheck/sales/state_transition.ex
```

### General policy stance

```text
system:
  allowed to run internal/system actions, create audit rows, and future worker transitions.

admin:
  allowed to read/manage Sales resources according to organization/event scope.
  allowed future management/manual-review actions only when those actions are added with explicit audit rules.

operator:
  allowed support-oriented read access only.
  may view dashboards/support state with PII masking where practical.
  must not access raw provider payloads by default.
  must not be equivalent to admin.

customer_session:
  no broad reads.
  no direct mutations.
  may only use future controlled service-flow actions or secure delivery-token flows.
  must not access payment internals, raw payloads, checkout internals, or delivery internals.
```

### Resource-specific policy notes

#### TicketOffer

```text
admin: read/manage later offer actions.
operator: read support/admin-visible offer data.
system: read active offers.
customer_session: only future controlled active-offer read path, not broad reads.
```

In VS-01F, if only basic read actions exist, test that customer_session cannot use broad read/list actions.

#### Order

```text
admin: scoped read/manage later.
operator: scoped support read only.
system: future payment/fulfillment transitions.
customer_session: no broad read; future secure token/order status path only.
```

Order PII must be guarded in tests where field policies or view-layer policy conventions exist.

#### OrderLine

```text
system/admin/operator: scoped reads where appropriate.
customer_session: no broad direct reads.
```

Historical price snapshots must not be mutable by customer_session/operator.

#### CheckoutSession

```text
system: future create/update/expiry/release.
admin/operator: support read only.
customer_session: no direct read.
```

Customer-facing checkout flows must call approved service/actions in later slices, not expose CheckoutSession broadly.

#### PaymentAttempt

```text
system: future create/update/verification transitions.
admin: restricted read including raw fields only where approved.
operator: read summary only; no raw provider responses.
customer_session: no read.
```

Raw fields requiring restricted access:

```text
raw_initialize_response
raw_verify_response
authorization_url
access_code
failure_message where it may contain provider data
```

#### PaymentEvent

```text
system: create/process future webhook events.
admin: restricted raw payload access.
operator: summarized read only.
customer_session: no read.
```

Raw fields requiring restricted access:

```text
raw_payload
payload_hash is not raw but should still not be customer-visible
last_processing_error if it may contain provider data
```

#### TicketIssue

```text
system: future issuance/revocation transitions.
admin/operator: support read with token hashes hidden or carefully restricted.
customer_session: no broad read; future secure delivery token flow only.
```

Token/hash-sensitive fields:

```text
qr_token_hash
delivery_token_hash
```

Customer-facing delivery tokens must never be stored in plaintext or returned by broad Ash reads.

#### DeliveryAttempt

```text
system: future create/update delivery transitions.
admin/operator: support read with recipient masking where practical.
customer_session: no broad read.
```

Restricted fields:

```text
recipient
provider_message_id
provider_error_message if it may contain provider/customer detail
correlation_id if internal-only
```

#### Conversation

```text
system: future create/update from webhook/conversation workers.
admin/operator: support read with PII restrictions.
customer_session: no direct read.
```

Restricted fields:

```text
phone_e164
wa_id
state_data
last_inbound_message_id
last_outbound_message_id
```

#### StateTransition

```text
system: create/record transitions.
admin/operator: read audit timelines according to scope.
customer_session: no direct read.
no update.
no destroy.
```

StateTransition must remain append-only.

---

## 6. Required File Outputs

Expected files or equivalent project-convention paths:

```text
lib/fastcheck/sales.ex
lib/fastcheck/sales/ticket_offer.ex
lib/fastcheck/sales/order.ex
lib/fastcheck/sales/order_line.ex
lib/fastcheck/sales/checkout_session.ex
lib/fastcheck/sales/payment_attempt.ex
lib/fastcheck/sales/payment_event.ex
lib/fastcheck/sales/ticket_issue.ex
lib/fastcheck/sales/delivery_attempt.ex
lib/fastcheck/sales/conversation.ex
lib/fastcheck/sales/state_transition.ex

test/fastcheck/sales/*policy*test.exs or equivalent
test/fastcheck/sales/*vs_01f*test.exs or equivalent
docs/fastcheck_sales/slices/VS-01F_ASH_POLICY_FOUNDATION.md
```

Optional helper module if the existing project style supports it:

```text
lib/fastcheck/sales/actor.ex
lib/fastcheck/sales/policies.ex
```

Do not create these helpers if project conventions prefer inline actor maps/policies. Keep it simple.

---

## 7. Forbidden File Outputs

This slice must not create or modify provider/runtime files:

```text
lib/fastcheck/sales/inventory/*
lib/fastcheck/payments/paystack/*
lib/fastcheck/messaging/whatsapp/*
lib/fastcheck/tickets/issuer.ex
lib/fastcheck/tickets/code_generator.ex
lib/fastcheck/tickets/qr_payload.ex
lib/fastcheck/tickets/delivery_token.ex
lib/fastcheck/workers/*
lib/fastcheck_web/controllers/webhooks/*
lib/fastcheck_web/controllers/ticket_delivery_controller.ex
lib/fastcheck_web/live/sales/*
existing scanner hot-path files
existing Attendee mutation/reconciliation files
existing Android/mobile API files
```

If a tiny test support module is needed to construct actors, place it under test support according to project conventions and keep it isolated.

---

## 8. RED/GREEN Test Plan

This slice is policy-heavy. The coding agent must write tests that fail before the policy implementation and pass after it.

### RED tests — must fail before implementation

Create tests that initially fail because policies are missing or too permissive.

Required RED expectations:

```text
customer_session cannot broadly read TicketOffer.
customer_session cannot broadly read Order.
customer_session cannot broadly read OrderLine.
customer_session cannot broadly read CheckoutSession.
customer_session cannot broadly read PaymentAttempt.
customer_session cannot broadly read PaymentEvent.
customer_session cannot broadly read TicketIssue.
customer_session cannot broadly read DeliveryAttempt.
customer_session cannot broadly read Conversation.
customer_session cannot broadly read StateTransition.

operator cannot access PaymentAttempt raw_initialize_response/raw_verify_response.
operator cannot access PaymentEvent raw_payload.
operator cannot be authorized for destructive/admin-only actions.
admin can perform scoped reads where allowed.
system can perform internal/basic system reads/creates where allowed by existing skeleton actions.
StateTransition cannot be updated.
StateTransition cannot be destroyed.

if tenant/event isolation is accepted:
  admin/operator from another organization/event cannot list or read unrelated records.
```

Where Ash field-level policy support is awkward for skeleton resources, tests may assert approved query/action behavior instead of direct field projection. Do not fake test coverage by merely checking module existence.

### GREEN tests — must pass after implementation

Required GREEN expectations:

```text
mix compile passes.
formatting passes.
Sales resources compile with policies enabled.
actor fixtures/test helpers construct system/admin/operator/customer_session actors consistently.
customer_session broad reads are denied.
operator raw provider payload access is denied.
admin/system access behaves according to policy.
StateTransition remains append-only by policy/action availability.
policy tests cover all current Sales resources.
no provider, Redis, WhatsApp, ticket issuing, scanner, or admin UI behavior is added.
```

### Boundary regression tests

Add tests or static assertions where practical:

```text
No Paystack HTTP modules were added.
No WhatsApp HTTP modules were added.
No Redis reservation modules were added.
No worker modules were added.
No LiveView admin modules were added.
No scanner hot-path files changed.
No generic update_status action exists.
```

---

## 9. Policy Matrix to Implement

Use this baseline matrix for current skeleton actions.

| Resource | system | admin | operator | customer_session |
|---|---:|---:|---:|---:|
| TicketOffer | read | read | read | no broad read |
| Order | read | read | read summary/support | no broad read |
| OrderLine | read | read | read support | no broad read |
| CheckoutSession | read | read | read support | denied |
| PaymentAttempt | read/internal | restricted read | summary only | denied |
| PaymentEvent | create/read/internal later | restricted read | summary only | denied |
| TicketIssue | read/internal | read | read support | no broad read |
| DeliveryAttempt | read/internal | read | read support | denied |
| Conversation | read/internal | read support | read support | denied |
| StateTransition | create/read | read | read | denied |

Important:

```text
This matrix covers the skeleton stage only.
Later slices must add explicit action-level policies for create/update/transition actions as those actions are introduced.
Do not grant broad future permissions now to avoid later tests failing.
```

---

## 10. Implementation Guidance for Coding Agent

Use Ash 3.x policy conventions that match the installed Ash version and existing project style.

Preferred approach:

```text
Add policy blocks directly to each Sales resource.
Use a simple actor_type check helper if needed.
Keep actor handling explicit and boring.
Use tests to prove denies, not only allows.
Avoid over-abstracting policies before patterns are clear.
```

Avoid:

```text
Do not invent a second auth system.
Do not add broad bypass policies for admin/operator without tests.
Do not make customer_session a normal user role.
Do not expose raw provider payloads through normal read actions.
Do not create policies that depend on future fields/actions that do not exist yet.
Do not add `bypass always` policies just to make tests pass.
Do not weaken skeleton boundaries by adding workflow actions.
```

### Suggested actor helper shape

If a helper is useful, keep it minimal:

```text
%{
  actor_type: :system | :admin | :operator | :customer_session,
  actor_id: optional,
  organization_id: optional,
  allowed_event_ids: optional
}
```

Do not implement this exact shape blindly if the existing app already has a standard current-user/current-actor structure. Map existing auth into the Sales policy model.

---

## 11. Performance and Scaling Review

This slice should not add hot runtime behavior.

Performance rules:

```text
No Redis calls.
No Paystack calls.
No Meta calls.
No checkout hot path.
No scanner hot path.
No dashboard queries beyond tests.
Policy checks must not require broad table scans.
Tenant/event scoping, where present, must use indexed fields from prior skeleton slices.
```

Scaling questions the agent must answer in the slice doc:

```text
Do policy filters use indexed fields where query policies are added?
Could customer_session accidentally trigger large Sales queries? It must not.
Could operator support lists expose raw heavy payload columns? They must not.
Do any policies force loading associations in a high-volume path? Avoid it.
```

---

## 12. Security Review

Required security outcomes:

```text
customer_session cannot browse Sales records.
operator cannot see raw provider payloads by default.
operator cannot mutate core state.
admin and system are distinguishable.
StateTransition remains append-only.
PII and token-hash fields are treated as restricted.
No plaintext token behavior is introduced.
No secrets, provider access codes, raw payloads, or phone/email values are logged in tests or docs.
```

Manual review:

```text
Manual-review operations do not exist yet.
This pack only ensures future manual-review actions must be admin/system-gated and audited when added.
```

---

## 13. Acceptance Criteria

The slice is accepted only if all are true:

```text
All existing Sales skeleton resources compile with policy foundation.
Policy tests exist for every current Sales resource.
customer_session broad reads are denied.
operator raw provider payload access is denied or unavailable by design.
admin/system allowed behavior is tested.
StateTransition update/destroy is unavailable or denied.
No workflow actions are added.
No provider/Redis/WhatsApp/ticket/scanner/admin UI code is added.
Tenant/event scoping follows the accepted decision.
Slice documentation explains how later action policies must extend this baseline.
RED/GREEN tests are meaningful and pass.
```

---

## 14. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Add the VS-01F Ash policy foundation for existing FastCheck.Sales skeleton resources. |
| Objective | Protect Sales resources before admin, checkout, payment, WhatsApp, and ticket workflows are built, while keeping the slice skeleton-only and boundary-safe. |
| Output | Update `lib/fastcheck/sales.ex` and existing `lib/fastcheck/sales/*.ex` resource files with Ash policy blocks or approved policy scaffolding; add policy tests under `test/fastcheck/sales/`; add `docs/fastcheck_sales/slices/VS-01F_ASH_POLICY_FOUNDATION.md`. |
| Note | Use Ash 3.x policy conventions. Follow accepted VS-00A/VS-00B/VS-00C/VS-00D decisions. Actor types are `system`, `admin`, `operator`, and `customer_session`. `customer_session` must not broadly read or mutate Sales resources. `operator` must not see raw Paystack/Meta payloads or act as admin. `StateTransition` must remain append-only. Do not add Paystack, Meta, Redis, ticket issuance, scanner, Oban, LiveView, checkout, or WhatsApp behavior. Do not add workflow actions or generic `update_status`. If tenant/event isolation is accepted, policy filters must use indexed scope fields and tests must prove cross-scope denial. |

---

## 15. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales slice VS-01F — Ash Policy Foundation.

Use Ash 3.x. Work only on the existing FastCheck.Sales skeleton resources created by VS-01B through VS-01E.

Goal:
Add baseline Ash policies and RED/GREEN tests for:
- FastCheck.Sales.TicketOffer
- FastCheck.Sales.Order
- FastCheck.Sales.OrderLine
- FastCheck.Sales.CheckoutSession
- FastCheck.Sales.PaymentAttempt
- FastCheck.Sales.PaymentEvent
- FastCheck.Sales.TicketIssue
- FastCheck.Sales.DeliveryAttempt
- FastCheck.Sales.Conversation
- FastCheck.Sales.StateTransition

Actor model:
- system
- admin
- operator
- customer_session

Rules:
- customer_session must not broadly read or mutate Sales resources.
- operator must not access raw provider payloads or act as admin.
- admin and system must remain distinct.
- StateTransition must be append-only: no update/destroy.
- raw_initialize_response, raw_verify_response, raw_payload, authorization_url, access_code, phone/email/recipient/state_data/token-hash fields must be treated according to VS-00B.
- if tenant/event isolation is accepted, enforce scoped reads using existing indexed fields.

Scope:
- Add policy blocks or approved policy scaffolding.
- Add meaningful policy tests that fail before the policy work and pass after it.
- Add/update docs/fastcheck_sales/slices/VS-01F_ASH_POLICY_FOUNDATION.md.

Forbidden:
- Do not add checkout workflows.
- Do not add Paystack HTTP/client/webhook/verification behavior.
- Do not add Redis reservation/session/rate-limit behavior.
- Do not add Meta/WhatsApp client/webhook/menu behavior.
- Do not add ticket issuance, QR rendering, Attendee creation, scanner/mobile API changes, Oban workers, admin LiveViews, or public/customer APIs.
- Do not add generic update_status actions.
- Do not add broad bypass policies just to make tests pass.

Run:
- mix format
- mix compile
- relevant Sales policy tests
- full existing scanner/runtime tests if project convention requires regression proof

Report:
- files changed
- tests added
- actor policy matrix implemented
- any tenant/event isolation blocker
- confirmation that no forbidden boundary files were changed
```

---

## 16. Human Review Checklist

Reviewer must verify:

```text
Policy tests cover all current Sales resources.
customer_session is denied broad reads.
operator cannot access raw provider payloads.
operator is not treated as admin.
admin/system policies are not overly broad without tests.
StateTransition remains append-only.
No workflow actions were added.
No provider, Redis, WhatsApp, ticket issuing, scanner, worker, LiveView, or public API files were added.
No secrets/PII/token values appear in logs, fixtures, or docs.
Tenant/event scope follows the accepted decision.
Future slices can extend policies without deleting this foundation.
```
