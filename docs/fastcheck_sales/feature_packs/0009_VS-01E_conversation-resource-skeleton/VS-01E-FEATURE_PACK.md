# FastCheck Sales Feature Planning Pack — VS-01E Conversation Resource Skeleton

**Pack ID:** `0009_VS-01E_conversation-resource-skeleton`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0009_VS-01E_conversation-resource-skeleton`  
**Slice:** `VS-01E`  
**Slice name:** Conversation Resource Skeleton  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Ready for implementation only after VS-01C is accepted and VS-00A/VS-00B/VS-00C/VS-00D decisions are available  
**Primary area:** Ash / DB / Conversation Skeleton  
**Depends on:** VS-01C  
**Blocks:** VS-01F, VS-01G, VS-17, VS-18, VS-19, VS-20  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack creates the Ash resource skeleton for persisted WhatsApp conversation checkpoints:

```text
FastCheck.Sales.Conversation
```

This slice gives the Sales domain a durable table for:

```text
WhatsApp customer conversation checkpoints
language / locale preference
current conversation state
recoverable state_data checkpoints
human handoff flags
last inbound/outbound message identifiers
session/rate-limit key references
```

This is still a **skeleton slice**. It must not implement Meta Cloud API webhooks, WhatsApp sending, Redis hot session state, rate limiting, number-only menu behavior, Paystack link sending, checkout creation, payment authority, ticket issuing, delivery fallback, Oban workers, admin UI, or customer-facing APIs.

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

After VS-01E is complete:

```text
The FastCheck.Sales Ash domain registers one additional resource:
  Conversation

The database has one corresponding table:
  sales_conversations

Conversation can be related to Order records.
Conversation stores durable checkpoint data only.
Redis remains the future hot active-session authority.
No Meta webhook, Meta client, Redis session, menu state machine, checkout flow, payment flow, ticket delivery, or human-handoff UI exists yet.
RED/GREEN tests prove the resource skeleton, migration, fields, relationships, indexes, and forbidden boundaries.
```

---

## 3. Scope

### In scope

```text
Inspect existing Ash, Ecto, Repo, migration, and test conventions.
Create FastCheck.Sales.Conversation resource skeleton.
Register Conversation in FastCheck.Sales.
Create database migration for sales_conversations.
Add required fields, identities, and indexes for this slice.
Add relationship declaration from Conversation to Order where appropriate.
Add relationship declaration from Order to Conversation if not already present and if prior skeleton conventions allow it.
Add basic read/list actions only.
Add tests for resource registration, migration, fields, indexes, relationships, and forbidden boundaries.
Add/update slice documentation.
Run format, compile, migration, and test commands.
```

### Out of scope

```text
No Meta Cloud API outbound client.
No Meta inbound webhook controller.
No webhook signature verification.
No WhatsApp message sending.
No WhatsApp number-only menu implementation.
No Redis session implementation.
No Redis rate-limit implementation.
No conversation state-machine transition actions.
No checkout creation from conversation.
No Paystack payment link generation or sending.
No ticket resend flow.
No DeliveryAttempt creation.
No Oban workers.
No admin/human-handoff UI.
No customer-facing API.
No scanner/mobile API changes.
No existing Attendee or Event changes.
No generic update_status action.
No broad customer_session read access.
```

---

## 4. Required Pre-Implementation Decisions

The coding agent must read the accepted outputs from VS-00A, VS-00B, VS-00C, VS-00D, VS-01A, VS-01B, and VS-01C before implementation.

### Tenant / organization decision

This slice must follow the accepted tenant model.

Rules:

```text
If multi_tenant or future_multi_tenant_prepared is accepted:
  include organization_id or the approved tenant/owner key on sales_conversations if prior Sales tables use it.
  make sure later policies can scope Conversation support views by organization/event where possible.

If single_tenant is accepted:
  do not add organization_id blindly.
  document that the first release is intentionally single-tenant.

If no decision exists:
  stop and report blocker. Do not create migrations.
```

### WhatsApp-first channel decision

VS-00D must be accepted before this slice.

Rules:

```text
WhatsApp is the first and primary production customer sales channel.
Conversation is a durable checkpoint resource for that future channel.
Conversation does not own payment authority, inventory authority, ticket issuance authority, or scanner validity.
Secondary web/admin paths must not depend on Conversation unless explicitly needed later.
```

### State-machine decision

VS-00A must be accepted before this slice.

Rules:

```text
Conversation.state must use the accepted Conversation state vocabulary.
No transition actions are implemented in VS-01E.
No menu behavior is implemented in VS-01E.
The skeleton must not invent additional conversation states without updating the accepted matrix.
```

Preferred Conversation state set:

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

### Security / PII / token decision

VS-00B must be accepted before this slice.

Rules:

```text
phone_e164 is PII.
wa_id is customer/provider identifier data and must be treated as restricted.
state_data may contain PII and must be treated as restricted jsonb/map data.
last_inbound_message_id and last_outbound_message_id are provider identifiers and must not be logged casually.
No raw Meta/WhatsApp webhook payload storage is introduced in this skeleton.
No phone number, email, WhatsApp ID, access token, provider payload, or message body may be logged.
```

### Redis session decision

VS-00C must be accepted before this slice, but this slice does not implement Redis.

Rules:

```text
Conversation stores durable checkpoints only.
Future Redis hot session state must use approved keys from later WhatsApp/Redis slices.
session_key and rate_limit_key are references/keys only; this skeleton must not create or mutate Redis keys.
```

---

## 5. Ash Domain and Resource Details

### Domain

```text
FastCheck.Sales
```

The domain must register:

```text
FastCheck.Sales.Conversation
```

### Resource

```text
lib/fastcheck/sales/conversation.ex
```

Expected resource purpose:

```text
Persist durable WhatsApp conversation checkpoints and human handoff state.
```

### Table

```text
sales_conversations
```

### Required fields

Use existing project conventions for UUIDs, timestamps, and AshPostgres attributes.

```text
id
organization_id       # only if accepted tenant model requires it
phone_e164
wa_id
session_key
rate_limit_key
preferred_language
locale
state
state_data
last_inbound_message_id
last_outbound_message_id
last_message_at
expires_at
needs_human
handoff_reason
inserted_at
updated_at
```

### Field guidance

```text
phone_e164: normalized E.164 string where possible; PII.
wa_id: provider/customer WhatsApp identifier; restricted.
session_key: future Redis session key reference; no Redis mutation in this slice.
rate_limit_key: future Redis rate-limit key reference; no Redis mutation in this slice.
preferred_language: constrained string/enum, default should align with Afrikaans-first policy.
locale: optional locale string such as af_ZA or en_ZA if accepted by project conventions.
state: constrained Conversation state value from VS-00A.
state_data: map/jsonb checkpoint data, restricted because it may contain PII.
last_inbound_message_id: provider message id, restricted.
last_outbound_message_id: provider message id, restricted.
last_message_at: UTC timestamp.
expires_at: UTC timestamp for durable conversation checkpoint expiry.
needs_human: boolean, default false.
handoff_reason: restricted support text; nullable.
```

### Relationships

```text
Conversation has_many Orders.
Order belongs_to Conversation if not already represented and if prior skeleton conventions allow it.
```

Relationship notes:

```text
Do not force every Order to have a Conversation.
Web/admin/internal-pilot sales may not have WhatsApp conversation records.
Conversation must not become a required dependency for non-WhatsApp channels.
```

### Allowed actions in this slice

Only basic safe actions:

```text
read
get_by_id
list_recent
list_needing_human
list_by_phone
```

The exact names may follow existing project conventions.

### Forbidden actions in this slice

Do not implement:

```text
start_or_resume
select_language
move_to_main_menu
select_event
select_offer
select_quantity
collect_buyer_name
collect_email
confirm_order
mark_awaiting_payment
mark_payment_pending
mark_ticket_issued
mark_needs_human
expire_conversation
any generic update_status action
any WhatsApp menu transition action
any Redis-backed session action
any Paystack/payment action
any ticket delivery/resend action
```

Reason:

```text
VS-01E creates the durable shape only.
Conversation workflow behavior belongs to later WhatsApp/conversation slices after policies, Redis session behavior, Meta API boundaries, and checkout contracts are ready.
```

---

## 6. Migration and Index Requirements

### Table

```text
sales_conversations
```

### Required indexes

```text
index(phone_e164)
index(needs_human, last_message_at)
index(state, expires_at)
```

Recommended additional indexes if supported by project conventions:

```text
index(wa_id)
index(session_key)
index(last_message_at)
```

If tenanting is accepted:

```text
index(organization_id, phone_e164)
index(organization_id, needs_human, last_message_at)
index(organization_id, state, expires_at)
```

### Uniqueness decision

Do not create a broad unique index on `phone_e164` unless the accepted conversation policy requires one.

Preferred safe rule:

```text
A phone number may have historical conversations.
Uniqueness, if needed, should apply only to an active/session key concept and must be defined in the accepted state/session policy.
```

Possible future index, not required in this skeleton unless already accepted:

```text
unique(session_key) where session_key is not null
```

---

## 7. Performance and Scaling Review

### Data layer classification

```text
Hot data:
  active WhatsApp session state in future Redis slice, not this table

Warm data:
  recent conversation support summaries may be cached later if needed

Cold durable data:
  sales_conversations table
```

### Performance rules

```text
This slice must not put active conversation turns on Postgres hot path.
Future WhatsApp inbound processing must use Redis for hot session/rate-limit operations.
Postgres Conversation rows are durable checkpoints and support/audit records.
Admin/support lists must use indexed query paths.
Large conversation state_data must not be loaded in broad list views unless specifically needed.
```

### Cache / Redis impact

```text
No Redis implementation in this slice.
No Cachex implementation in this slice.
No PubSub implementation in this slice.
```

Future rules to preserve:

```text
Meta inbound webhook hot path should update Redis first and persist durable checkpoints deliberately.
Conversation checkpoint updates should avoid excessive DB writes during high-volume chat bursts.
Human-handoff support lists should be index-backed or cached.
```

---

## 8. Security and PII Review

### Sensitive fields

```text
phone_e164
wa_id
state_data
last_inbound_message_id
last_outbound_message_id
handoff_reason
```

### Security rules

```text
No raw WhatsApp webhook payloads are stored in this skeleton.
No message bodies are stored unless explicitly approved by VS-00B policy.
No phone numbers, wa_id values, provider message IDs, or state_data contents are logged.
Operator access to Conversation must be restricted in later policy slice.
customer_session must not broadly read Conversation records.
Admin/support list views should mask phone values by default when UI is created later.
```

### Token rules

```text
No tokens are generated or stored in this slice.
Do not add access tokens, Meta tokens, delivery tokens, or QR tokens to Conversation.
```

---

## 9. RED / GREEN Test Plan

The coding agent must write tests in RED/GREEN style.

### RED tests must fail before implementation when:

```text
FastCheck.Sales.Conversation module is missing.
FastCheck.Sales does not register Conversation.
sales_conversations table is missing.
required fields are missing.
required indexes are missing.
Conversation relationship to Order is missing where accepted by prior resource shape.
Order relationship to Conversation is missing where accepted by prior resource shape.
state is unconstrained or does not follow the accepted VS-00A state vocabulary.
state_data is not map/jsonb-compatible.
needs_human default is missing or unsafe.
basic read/list actions are missing.
workflow transition actions exist too early.
Meta/WhatsApp HTTP modules are introduced.
Redis session/rate-limit modules are introduced.
webhook controllers are introduced.
Oban workers are introduced.
conversation menus are introduced.
PII fields are logged in tests or implementation.
Conversation becomes required for non-WhatsApp orders.
```

### GREEN tests must pass after implementation when:

```text
mix compile passes.
formatting passes.
migrations create only the intended sales_conversations table.
FastCheck.Sales.Conversation compiles with AshPostgres.
FastCheck.Sales registers Conversation.
required fields exist.
required indexes exist.
relationships to Order follow accepted prior skeleton conventions.
basic read/list actions work.
no workflow transition actions exist in this slice.
no Meta/WhatsApp HTTP code exists.
no Redis session/rate-limit code exists.
no webhook controllers or workers exist.
no PII logging is introduced.
Conversation remains optional for orders created by secondary non-WhatsApp channels.
```

### Suggested test files

Use project conventions, but expected locations are similar to:

```text
test/fastcheck/sales/conversation_test.exs
test/fastcheck/sales/vs_01e_conversation_resource_skeleton_test.exs
```

### Test categories

```text
resource registration tests
migration/table tests
field existence tests
index existence tests
relationship tests
basic read action tests
forbidden action tests
forbidden file/module tests
PII/logging guard tests if project has log-capture conventions
```

---

## 10. Acceptance Criteria

VS-01E is accepted only when:

```text
FastCheck.Sales.Conversation exists.
FastCheck.Sales registers Conversation.
sales_conversations migration exists and creates only the intended table.
All required fields exist using accepted project conventions.
Indexes for phone/support/state expiry query paths exist.
Conversation has relationship support for Orders without making Conversation mandatory for all Orders.
Only basic read/list actions exist.
No conversation workflow actions exist.
No Redis, Meta, webhook, payment, ticket, delivery, or worker behavior is introduced.
No PII logging or raw WhatsApp payload storage is introduced.
Tests prove RED/GREEN expectations.
Existing scanner, Attendee, Event, Tickera sync, Android/mobile API, Paystack, Redis, and Ticketing files are untouched unless only documentation references are updated.
```

---

## 11. Required Output Files

Expected new/changed files:

```text
lib/fastcheck/sales.ex
lib/fastcheck/sales/conversation.ex
priv/repo/migrations/*create_sales_conversations*.exs
test/fastcheck/sales/*conversation*test.exs
docs/fastcheck_sales/slices/VS-01E_CONVERSATION_RESOURCE_SKELETON.md
```

Allowed relationship touch points if required by existing resource conventions:

```text
lib/fastcheck/sales/order.ex
```

Forbidden new files:

```text
lib/fastcheck/messaging/whatsapp/*
lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex
lib/fastcheck/sales/inventory/*
lib/fastcheck/payments/paystack/*
lib/fastcheck/tickets/*
lib/fastcheck/workers/*
lib/fastcheck_web/live/sales/*
existing scanner hot-path files
existing Attendee mutation/reconciliation files
existing Android/mobile API files
```

---

## 12. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Create the `FastCheck.Sales.Conversation` Ash resource skeleton for durable WhatsApp conversation checkpoints. |
| Objective | Add the durable checkpoint table needed for the WhatsApp-first channel while keeping hot session state, Meta API calls, Redis state, checkout, payment, ticket issuing, and delivery behavior outside this slice. |
| Output | `lib/fastcheck/sales/conversation.ex`, updated `lib/fastcheck/sales.ex`, one migration for `sales_conversations`, resource/migration/index/relationship tests, and `docs/fastcheck_sales/slices/VS-01E_CONVERSATION_RESOURCE_SKELETON.md`. |
| Note | Use Ash 3.x and existing project conventions. Add only skeleton fields, indexes, identities, relationships, timestamps, and basic read/list actions. Required fields: `phone_e164`, `wa_id`, `session_key`, `rate_limit_key`, `preferred_language`, `locale`, `state`, `state_data`, `last_inbound_message_id`, `last_outbound_message_id`, `last_message_at`, `expires_at`, `needs_human`, `handoff_reason`, plus tenant key only if accepted. Required indexes: `phone_e164`, `(needs_human, last_message_at)`, `(state, expires_at)`, plus tenant-scoped equivalents if accepted. `state_data` must be map/jsonb-compatible and treated as restricted. Do not implement Meta API, webhook controllers, Redis session/rate limiting, conversation menus, checkout creation, payment behavior, ticket delivery, Oban workers, admin UI, or generic status updates. Conversation is optional for non-WhatsApp sales paths. RED tests must fail when the resource/table/indexes are missing or forbidden behavior appears. GREEN tests must pass with only the skeleton behavior. No PII/logging leaks. |

---

## 13. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales slice VS-01E — Conversation Resource Skeleton.

Goal:
Create only the Ash resource skeleton for FastCheck.Sales.Conversation and the sales_conversations table.

Context:
FastCheck Sales is multi-channel, but WhatsApp is first. Conversation exists to store durable WhatsApp conversation checkpoints. It does not own hot session state, Meta API behavior, payment authority, inventory authority, ticket issuing, delivery, scanner validity, or admin UI.

Required work:
1. Inspect existing Ash/Ecto/Repo/migration/test conventions.
2. Add lib/fastcheck/sales/conversation.ex.
3. Register Conversation in lib/fastcheck/sales.ex.
4. Add migration for sales_conversations.
5. Add required fields:
   - phone_e164
   - wa_id
   - session_key
   - rate_limit_key
   - preferred_language
   - locale
   - state
   - state_data
   - last_inbound_message_id
   - last_outbound_message_id
   - last_message_at
   - expires_at
   - needs_human
   - handoff_reason
   - timestamps
   - organization_id only if accepted tenant decision requires it.
6. Add indexes:
   - phone_e164
   - needs_human, last_message_at
   - state, expires_at
   - tenant-scoped equivalents only if tenanting is accepted.
7. Add Conversation has_many Orders and Order belongs_to Conversation only according to existing/prior skeleton conventions.
8. Add only basic read/list actions.
9. Add RED/GREEN tests proving resource registration, migration, fields, indexes, relationships, and forbidden boundaries.
10. Add/update docs/fastcheck_sales/slices/VS-01E_CONVERSATION_RESOURCE_SKELETON.md.

Forbidden:
- No Meta API modules.
- No WhatsApp webhook controller.
- No Redis session/rate-limit implementation.
- No conversation menu behavior.
- No conversation workflow transition actions.
- No checkout creation.
- No Paystack behavior.
- No ticket delivery/resend behavior.
- No Oban workers.
- No admin UI.
- No scanner/Attendee/Event/Android API changes.
- No generic update_status action.
- No PII logging.

Tests:
RED tests should fail before the resource/table/indexes exist or if forbidden behavior appears.
GREEN tests should pass once the skeleton exists and forbidden behavior is absent.

Run format, compile, migrations, and relevant tests. Report changed files and confirm forbidden files were not touched.
```

---

## 14. Human Review Checklist

Before accepting the slice, verify:

```text
Conversation is registered in FastCheck.Sales.
sales_conversations table exists.
Fields match the accepted atlas.
Indexes match support/query paths.
Conversation does not require all Orders to be WhatsApp-originated.
Only basic reads/lists exist.
No workflow transition actions exist.
No Meta/WhatsApp API code exists.
No Redis session/rate-limit code exists.
No Paystack/ticket/delivery/worker behavior exists.
No scanner/Attendee/Event/Android API files were modified.
state_data and PII fields are treated as restricted.
No raw WhatsApp payload storage was added.
Tests prove missing skeleton fails and completed skeleton passes.
```

---

## 15. Next Slice

After VS-01E is accepted, continue with:

```text
VS-01F — Ash Policy Foundation
```

Do not start VS-01F until the resource skeleton set is stable enough to apply consistent policy rules across:

```text
TicketOffer
Order
OrderLine
CheckoutSession
PaymentAttempt
PaymentEvent
TicketIssue
DeliveryAttempt
Conversation
StateTransition
```
