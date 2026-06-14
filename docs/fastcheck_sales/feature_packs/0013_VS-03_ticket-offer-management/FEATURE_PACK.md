# FastCheck Sales Feature Planning Pack — VS-03 Ticket Offer Management

**Pack ID:** `0013_VS-03_ticket-offer-management`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0013_VS-03_ticket-offer-management`  
**Slice:** `VS-03`  
**Slice name:** Ticket Offer Management  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Ready for implementation only after VS-01B, VS-01F, VS-01G, and all planning gates are accepted  
**Primary area:** Ash / Sales / TicketOffer / Admin Actions / Cache Contract / Tests  
**Depends on:** VS-00A, VS-00B, VS-00C, VS-00D, VS-01A, VS-01B, VS-01F, VS-01G  
**Blocks:** VS-04A, VS-04B, VS-05, VS-05A  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack implements admin-manageable sellable ticket offers for FastCheck Sales.

`FastCheck.Sales.TicketOffer` is the durable configuration record that defines what may be sold for an event. It owns the stable offer details:

```text
name
ticket_type
price_cents
currency
configured_quantity_available
initial_quantity
max_per_order
sales_enabled
sales_channel
starts_at
ends_at
archived_at
```

This slice does **not** implement live inventory, Redis reservation, checkout, Paystack, WhatsApp flow, or ticket issuance.

Strategic framing remains:

```text
FastCheck Sales is multi-channel, but WhatsApp is first.

Primary production customer channel:
  WhatsApp via Meta Cloud API

Secondary supported Sales paths:
  admin-assisted sales
  web checkout sales
  internal pilot sales

TicketOffer must support all channels, but no channel may bypass the same Sales core.
```

This slice creates the safe offer-management foundation that future inventory, checkout, WhatsApp, and admin surfaces will consume.

---

## 2. Ultimate Outcome

After VS-03 is complete:

```text
Admins can create and manage TicketOffer records through named Ash actions.
Admins can enable or disable sales for an offer.
Operators can read offer data but cannot mutate it.
System/customer-session flows can only read active, enabled, in-window offers through controlled actions.
TicketOffer validations prevent unsafe price, quantity, currency, date, and per-order-limit values.
TicketOffer queries have indexed paths for event/active-offer listing.
Cache invalidation rules are explicit and testable.
TicketOffer remains durable configuration only; Redis owns live availability later.
No checkout, reservation, payment, WhatsApp, or ticket issuing behavior exists in this slice.
```

The goal is a safe offer catalog, not a sale engine.

---

## 3. Scope

### In scope

```text
Implement TicketOffer named actions:
  create_offer
  update_offer
  enable_sales
  disable_sales
  list_active_for_event
  get_available_for_checkout

Add validations for:
  price_cents
  currency
  configured_quantity_available
  initial_quantity
  max_per_order
  starts_at / ends_at
  sales_channel
  event_id
  archived_at behavior

Add or verify Ash policies for:
  admin create/update/enable/disable
  operator read-only
  system controlled read
  customer_session controlled active-offer read only

Add or verify identities/indexes:
  unique(event_id, name) where archived_at is null
  index(event_id, sales_enabled, starts_at, ends_at)

Define a cache invalidation contract for offer create/update/enable/disable/archive.
Add RED/GREEN tests for actions, policies, validations, active listing, and boundary rules.
Document confirmed module paths and cache invalidation behavior.
```

### Out of scope

```text
No Redis live inventory implementation.
No Redis Lua scripts.
No inventory reservation, consume, release, or reconciliation.
No checkout session creation.
No Order or OrderLine workflow implementation.
No Paystack client or transaction initialization.
No Meta/WhatsApp integration.
No public checkout UI.
No admin LiveView dashboard unless the existing codebase requires a tiny smoke path; prefer no UI in this slice.
No ticket issuance.
No QR or delivery token generation.
No Attendee creation.
No scanner hot-path changes.
No Android/mobile API changes.
```

---

## 4. Required Pre-Implementation Decisions

The coding agent must read and follow accepted outputs from:

```text
VS-00A State Machine and Failure Policy Finalization
VS-00B Security, PII, and Token Policy Finalization
VS-00C Inventory Recovery and Reconciliation Contract
VS-00D MVP Purchase Entry-Point and Launch Scope Decision
VS-01B Core Sales Resource Skeletons
VS-01F Ash Policy Foundation
VS-01G Index and Migration Verification
```

### Required discovery step

Before editing code, the agent must locate and document actual repository paths for:

```text
FastCheck.Sales domain module
FastCheck.Sales.TicketOffer resource
TicketOffer migration(s)
Sales policy helpers / actor structs
Sales tests
Cachex configuration if already present
Phoenix PubSub module if already present
existing admin/event context conventions
existing Event schema or event ID type
```

Do not assume names if the repository differs.

### Tenant/event decision

Follow the accepted tenant decision from VS-00B / VS-01G.

If `organization_id` is accepted, all TicketOffer reads and writes must be tenant/event scoped. If the system is intentionally single-tenant for first release, the implementation must not add broad assumptions that make future organization scoping hard.

---

## 5. Ash Domain and Resource Details

### Ash domain

```text
FastCheck.Sales
```

### Resource modified

```text
FastCheck.Sales.TicketOffer
```

### Resource table

```text
sales_ticket_offers
```

### Required fields

Use the field contract from VS-01B. The slice may add missing fields only if VS-01B skeleton did not already create them.

```text
id
organization_id       # only if tenant model is accepted
event_id
name
ticket_type
price_cents
currency
configured_quantity_available
initial_quantity
max_per_order
sales_enabled
sales_channel
starts_at
ends_at
lock_version
archived_at
inserted_at
updated_at
```

### Field rules

```text
price_cents: integer, non-negative, no floats
currency: uppercase ISO 4217 string
configured_quantity_available: integer, >= 0
initial_quantity: integer, >= 0
max_per_order: integer, >= 1 and <= configured_quantity_available unless configured quantity is zero
sales_enabled: boolean, default false for safety unless product decision says otherwise
sales_channel: constrained value, not arbitrary text
starts_at / ends_at: UTC timestamps; ends_at must be after starts_at when both exist
archived_at: nullable UTC timestamp; archived offers are excluded from active/customer lists
lock_version: optimistic locking for admin edits
```

### Recommended sales_channel values

Minimum values:

```text
whatsapp
admin
web
all
internal
```

Rules:

```text
whatsapp is the primary production channel.
admin and web are valid secondary supported sales paths.
internal is for pilot/testing only and must not be exposed as public production checkout.
all means the offer can be used by every enabled channel, but all channels still use the same inventory, payment, and issuing core.
```

---

## 6. Required Actions

### create_offer

Purpose:

```text
Create a durable sellable offer configuration for an event.
```

Actor:

```text
admin only
```

Must validate:

```text
event_id exists or is structurally valid according to existing Event model
name is present
ticket_type is present or valid according to existing event/ticket conventions
price_cents is integer and non-negative
currency is uppercase ISO 4217
configured_quantity_available and initial_quantity are non-negative integers
max_per_order is at least 1 and does not exceed configured quantity unless approved policy allows it
starts_at/ends_at window is valid
sales_channel is one of the accepted values
```

Must not:

```text
create Redis inventory keys directly
create orders
create order lines
start checkout
call Paystack
send WhatsApp messages
```

Cache effect:

```text
must call/emit the agreed offer-cache invalidation contract after success
```

### update_offer

Purpose:

```text
Update durable offer configuration safely.
```

Actor:

```text
admin only
```

Must validate the same invariants as create.

Must use optimistic-lock behavior through `lock_version` or equivalent if the resource supports it.

Important rule:

```text
Updating configured_quantity_available is not a live inventory mutation during active sale windows.
VS-04 owns Redis live availability and reconciliation rules.
```

Cache effect:

```text
must invalidate event-offer caches after success
```

### enable_sales

Purpose:

```text
Mark an offer as sales-enabled if it is structurally valid.
```

Actor:

```text
admin only
```

Must require:

```text
not archived
valid price/currency
valid configured quantity
valid max_per_order
valid sales window or intentionally open-ended sales window
```

Must not require Redis inventory implementation in this slice.

### disable_sales

Purpose:

```text
Mark an offer as not sales-enabled.
```

Actor:

```text
admin only
```

Must be safe and idempotent.

Must not release Redis holds because VS-04/VS-14 own live inventory and expiry behavior.

### list_active_for_event

Purpose:

```text
Return active, enabled, non-archived offers for an event.
```

Actor:

```text
admin/operator/system/customer_session through policy-controlled reads
```

Must filter:

```text
event_id
sales_enabled = true
archived_at is null
starts_at is null or starts_at <= now
ends_at is null or ends_at > now
sales_channel matches requested channel or all
organization/tenant scope if applicable
```

Must not expose inactive/disabled/archived offers to customer_session.

### get_available_for_checkout

Purpose:

```text
Return a structurally valid, active offer for checkout flow to use.
```

Important boundary:

```text
This action does not own live availability.
It may confirm the offer is enabled/in-window/non-archived.
Future VS-04/VS-05 must use ReservationLedger for live availability and hold creation.
```

Must not:

```text
read Redis live availability inside the Ash resource
reserve inventory
create checkout session
create order
```

---

## 7. Policy Requirements

### admin

Allowed:

```text
create_offer
update_offer
enable_sales
disable_sales
read/list all scoped offers
```

### operator

Allowed:

```text
read/list scoped offers
```

Forbidden:

```text
create/update/enable/disable
raw broad tenantless reads if tenanting is enabled
```

### system

Allowed:

```text
read/list active offers through controlled actions
```

Forbidden:

```text
mutating offers unless an explicit future system maintenance action is approved
```

### customer_session

Allowed:

```text
list_active_for_event through controlled service flow only
get_available_for_checkout through controlled service flow only
```

Forbidden:

```text
broad reads
inactive/disabled/archived offers
admin/internal-only offers unless explicitly allowed by channel policy
all mutation actions
```

---

## 8. Cache, PubSub, and Performance Rules

### Data layer classification

```text
TicketOffer durable configuration: Postgres cold/durable source of truth
Active offer display: Cachex hot cache, 1–5 minute TTL
Event offer list warm cache: Redis key sales:event:{event_id}:offers, 30 minute TTL
Live sale availability: Redis inventory ledger, future VS-04/VS-05 only
```

### Cache invalidation contract

This slice must define or use a minimal boundary such as:

```text
FastCheck.Sales.Offers.CacheInvalidation.invalidate_event_offers(event_id)
```

or an existing project-equivalent module.

Required invalidation triggers:

```text
create_offer
update_offer
enable_sales
disable_sales
archive_offer if archive exists now or later
```

Required cache effects:

```text
invalidate Cachex active-offer cache
invalidate Redis warm event-offer cache if already implemented
broadcast Phoenix PubSub offer update if PubSub display is already part of the app
```

If Redis warm cache or PubSub is not yet implemented, this slice must still document the contract and leave a testable no-op/stub boundary rather than baking cache logic directly into many actions.

### Performance requirements

```text
list_active_for_event must use indexed query paths.
Do not scan all offers across all events during checkout/customer menu flows.
Do not compute live availability from Postgres configured_quantity_available.
Do not introduce dashboard or customer list queries that lack event/status/window indexes.
```

---

## 9. Required File Areas

The agent must discover exact paths. Expected paths may include:

```text
lib/fastcheck/sales.ex
lib/fastcheck/sales/ticket_offer.ex
priv/repo/migrations/*sales_ticket_offers*.exs
test/fastcheck/sales/ticket_offer_test.exs
test/fastcheck/sales/ticket_offer_policy_test.exs
lib/fastcheck/sales/offers/cache_invalidation.ex    # if created
```

Allowed new helper module if needed:

```text
lib/fastcheck/sales/offers/cache_invalidation.ex
```

The helper must be tiny and focused. Do not build a broad offer service layer unless the existing project style already uses that pattern.

---

## 10. RED/GREEN Test Plan

The implementation must be driven by tests.

### RED tests that must fail before implementation

Write or confirm tests that fail when:

```text
admin cannot create a valid offer
non-admin can create/update/enable/disable an offer
operator can mutate an offer
customer_session can read disabled, archived, out-of-window, or wrong-channel offers
negative price_cents is accepted
float money values are accepted
invalid currency is accepted
configured quantity or initial quantity can be negative
max_per_order can be zero or invalid
ends_at before starts_at is accepted
archived offers appear in active/customer lists
list_active_for_event returns wrong-event offers
the unique active offer name constraint is missing or unenforced
cache invalidation contract is not called/documented on create/update/enable/disable
get_available_for_checkout reserves inventory or calls Redis directly
TicketOffer uses Postgres configured quantity as live checkout availability
Paystack, Meta, checkout, order creation, or ticket issuing code appears in this slice
```

### GREEN tests that must pass after implementation

Implementation is acceptable only when tests prove:

```text
admin can create/update/enable/disable valid scoped offers
operator can read but cannot mutate offers
customer_session only sees active, enabled, in-window, non-archived, channel-compatible offers through controlled actions
invalid price/currency/quantity/window/max_per_order data is rejected
unique(event_id, name) where archived_at is null is enforced
archived offers are excluded from active/customer lists
list_active_for_event uses event scope and active window filters
get_available_for_checkout confirms durable offer eligibility only and does not reserve inventory
cache invalidation contract is invoked or emitted after successful mutations
no Redis Lua, Paystack, Meta, checkout, order, ticket issuance, or scanner changes exist
```

### Suggested test files

Use existing test conventions. Likely files:

```text
test/fastcheck/sales/ticket_offer_test.exs
test/fastcheck/sales/ticket_offer_policy_test.exs
test/fastcheck/sales/ticket_offer_cache_invalidation_test.exs
test/fastcheck/sales/ticket_offer_boundary_test.exs
```

Keep tests focused. Do not create huge end-to-end tests in this slice.

---

## 11. Acceptance Criteria

This slice is accepted only when:

```text
TicketOffer actions are implemented as named Ash actions.
Admin/operator/system/customer_session policies are enforced.
Validations reject unsafe offer data.
Active offer listing respects event, window, enabled, archived, channel, and tenant scope.
Cache invalidation contract exists and is triggered or clearly emitted after offer mutations.
DB identities/indexes are verified and covered by tests.
No live inventory behavior is implemented.
No provider, checkout, issuance, scanner, WhatsApp, or UI scope creep exists.
RED/GREEN tests prove behavior and boundaries.
Slice documentation records actual file paths and any deviations from this pack.
```

---

## 12. Human Review Checklist

Reviewers must verify:

```text
TicketOffer remains durable offer configuration only.
No action acts as live inventory authority.
Customer_session cannot browse all offers.
Operator cannot mutate offers.
Admin mutations are audited or ready for StateTransition integration if the accepted policy requires it.
Cache invalidation is centralized and not scattered.
Indexes match the hardened atlas.
No broad table scans were introduced.
No Paystack/Meta/Redis/checkout/ticket issuing code slipped in.
WhatsApp-first strategy remains intact while allowing secondary sales channels.
```

---

## 13. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-03 Ticket Offer Management for `FastCheck.Sales.TicketOffer`. |
| Objective | Provide safe admin-managed sellable ticket offers that future WhatsApp-first, admin-assisted, and web checkout flows can consume without making TicketOffer the live inventory authority. |
| Output | Update `lib/fastcheck/sales/ticket_offer.ex` and related Sales domain/test files. Add a tiny cache invalidation boundary only if needed. Add focused tests for actions, policies, validations, active listing, indexes, and boundaries. Document actual file paths and deviations in `docs/fastcheck_sales/slices/VS-03_TICKET_OFFER_MANAGEMENT.md`. |
| Note | Use Ash 3.x patterns and existing project conventions. Implement named actions only: `create_offer`, `update_offer`, `enable_sales`, `disable_sales`, `list_active_for_event`, and `get_available_for_checkout`. Do not add generic `update_status`. Do not implement Redis inventory, checkout, Paystack, Meta API, QR, ticket issuance, Attendee creation, scanner changes, or UI. `configured_quantity_available` is durable configuration only; Redis will own live availability in VS-04/VS-05. Required indexes: `unique(event_id, name) where archived_at is null` and `index(event_id, sales_enabled, starts_at, ends_at)`, tenant-scoped if accepted. Cache rules: invalidate active-offer Cachex entries, Redis warm `sales:event:{event_id}:offers` if present, and PubSub display state if present; use a centralized boundary and no scattered side effects. TTLs: Cachex 1–5m, Redis warm 30m. All customer/session reads must be scoped by event, channel, enabled state, active window, archived status, and tenant if accepted. |

---

## 14. Copy-Paste Agent Prompt

```text
You are implementing FastCheck Sales slice VS-03 — Ticket Offer Management.

Read first:
- docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
- docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
- Feature pack: 0013_VS-03_ticket-offer-management/FEATURE_PACK.md

Goal:
Implement safe admin-managed `FastCheck.Sales.TicketOffer` behavior using Ash 3.x.

Scope:
- Implement named Ash actions: create_offer, update_offer, enable_sales, disable_sales, list_active_for_event, get_available_for_checkout.
- Add validations for price, currency, quantities, max_per_order, sales window, sales_channel, archived behavior, and tenant/event scope if accepted.
- Enforce policies: admin mutates, operator reads only, system controlled reads, customer_session controlled active-offer reads only.
- Verify required identities and indexes.
- Add a centralized cache invalidation boundary for offer changes if needed.
- Add RED/GREEN tests.
- Document actual paths and deviations in docs/fastcheck_sales/slices/VS-03_TICKET_OFFER_MANAGEMENT.md.

Hard boundaries:
- Do not implement Redis inventory or Lua.
- Do not reserve/consume/release inventory.
- Do not implement checkout sessions, orders, Paystack, Meta/WhatsApp, QR, ticket issuance, Attendee creation, scanner changes, Android/mobile changes, or UI.
- Do not treat configured_quantity_available as live availability.
- Do not add generic update_status actions.

Test requirements:
- RED tests must fail for invalid money/currency/quantity/window/channel inputs, forbidden actor mutations, customer_session broad reads, archived/out-of-window offer exposure, missing unique identity behavior, missing cache invalidation contract, and boundary creep.
- GREEN tests must prove valid admin actions, correct policy enforcement, active-offer filtering, cache invalidation, required indexes, and no forbidden side effects.

Performance/caching:
- Active offer display can use Cachex 1–5m TTL.
- Warm event offers may use Redis key sales:event:{event_id}:offers with TTL 30m if that cache exists.
- Mutations must invalidate relevant caches via a central boundary.
- list_active_for_event must use indexed query paths.

Return a concise implementation summary with files changed, tests added, tests run, and any unresolved issues.
```

---

## 15. Success Signal

This pack succeeds when a reviewer can say:

```text
Ticket offers are safe to manage.
Customer-visible offer reads are scoped and filtered.
Admins can enable/disable offers without touching live inventory.
The future Redis inventory ledger can build on these offers cleanly.
No payment, checkout, WhatsApp, scanner, or ticket issuance authority leaked into TicketOffer.
```
