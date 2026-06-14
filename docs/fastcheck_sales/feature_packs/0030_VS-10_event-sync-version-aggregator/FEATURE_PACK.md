# FastCheck Sales Feature Planning Pack — VS-10 Event Sync Version Aggregator

**Pack ID:** `0030_VS-10_event-sync-version-aggregator`  
**Slice:** `VS-10`  
**Slice name:** Event Sync Version Aggregator  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** Implementation-facing infrastructure pack  
**Primary repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0030_VS-10_event-sync-version-aggregator`  
**Primary area:** Events / Mobile Sync / Scanner Visibility / Cache Invalidation / Sales Ticket Issuance Propagation  
**Depends on:** VS-09B, VS-09C, VS-09D, VS-02, VS-01D, VS-01G, VS-21A  
**Blocks:** VS-11, VS-12, VS-15A, VS-15B, VS-19, VS-22  

**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

VS-10 creates the **single approved sync-version aggregation boundary** for any transaction that changes scanner/mobile-visible attendee or ticket state.

Current FastCheckin already has:

```text
FastCheck.Events.Event.event_sync_version
FastCheck.Events.bump_event_sync_version!/1
FastCheck.Attendees.Reconciliation.apply_after_authoritative_snapshot/3
FastCheckWeb.Mobile.SyncController.get_attendees/2
FastCheck.Cache.EtsLayer attendee/event ETS tables
FastCheck.Attendees.Cache Cachex-backed attendee lookup/list caching
```

The missing piece is a small, explicit service that new Sales issuance/revocation flows can call so they do not scatter version bumps, cache invalidation, stats refresh, and PubSub broadcasts across issuer code.

Target mental model:

```text
Sales issuance / attendee creation / TicketIssue linking / future revocation
  -> durable transaction succeeds
  -> FastCheck.Events.MobileSyncVersionAggregator.after_attendee_visibility_change(...)
  -> event_sync_version increments once
  -> attendee/event caches invalidated precisely
  -> optional PubSub/stat broadcast emitted
  -> mobile scanners can see active attendees or invalidations through the existing sync-down API
```

---

## 2. FastCheckin Current-State Findings

Use the real FastCheckin codebase, not `vg_app`.

### Existing event version field

`FastCheck.Events.Event` already has `event_sync_version` with default `0`, described as a monotonic version for mobile attendee/invalidation sync.

### Existing mobile sync endpoint

`FastCheckWeb.Router` exposes authenticated mobile sync routes:

```text
GET  /api/v1/mobile/attendees
POST /api/v1/mobile/scans
```

`FastCheckWeb.Mobile.SyncController` already returns:

```text
attendees
invalidations
invalidations_checkpoint
event_sync_version
```

It only exports attendees whose `scan_eligibility` is `active` or nil.

### Existing Tickera reconciliation behavior

`FastCheck.Attendees.Reconciliation.apply_after_authoritative_snapshot/3` already:

```text
marks absent active attendees as not_scannable
writes AttendeeInvalidationEvent rows
bumps Events.bump_event_sync_version!(event_id)
```

### Existing hot/warm cache behavior

`FastCheck.Cache.EtsLayer` stores hot attendees by `{event_id, ticket_code}` and can invalidate all attendees for an event or delete one attendee key.

`FastCheck.Attendees.Cache` uses ETS + Cachex for attendee lookup and event attendee lists.

### Important design implication

VS-10 must **centralize** new Sales-origin sync visibility updates, but it must not break the existing Tickera reconciliation path.

---

## 3. Ultimate Outcome

After VS-10:

```text
There is one approved module/function for mobile-sync-visible event changes.
Sales issuance can make newly created attendees visible to scanners without ad-hoc cache invalidation.
Future revocation/refund can create invalidation rows and bump the same event version.
Existing Tickera reconciliation behavior remains intact.
Existing mobile sync contract remains unchanged.
Scanner acceptance logic remains unchanged.
Each business transaction bumps event_sync_version at most once.
Cache invalidation is scoped by event and/or ticket code.
Tests prove no duplicate version storms under multi-ticket order issuance.
```

---

## 4. Scope

### In scope

```text
Add `FastCheck.Events.MobileSyncVersionAggregator` or similarly named module.
Expose explicit functions for attendee visibility changes.
Call existing `FastCheck.Events.bump_event_sync_version!/1` exactly once per completed export-affecting transaction.
Invalidate attendee caches affected by new attendees or status changes.
Invalidate event-level attendee list cache.
Optionally broadcast existing event stats/occupancy updates if current modules already provide stable functions.
Add tests proving aggregator behavior for Sales-created attendees and future invalidation-ready changes.
Document when issuance code should call the aggregator.
```

### Out of scope

```text
No scanner acceptance logic changes.
No mobile API response shape changes.
No Android client changes.
No TicketIssue creation changes.
No Attendee creation changes except possibly using the aggregator from issuer code.
No Paystack behavior.
No WhatsApp/email delivery.
No Redis inventory mutation.
No revocation/refund implementation.
No new analytics dashboard.
```

---

## 5. Recommended Module and File Paths

Preferred new file:

```text
lib/fastcheck/events/mobile_sync_version_aggregator.ex
```

Preferred test file:

```text
test/fastcheck/events/mobile_sync_version_aggregator_test.exs
```

Potential integration tests, only if needed:

```text
test/fastcheck/tickets/issuer_mobile_sync_test.exs
test/fastcheck_web/controllers/mobile/sync_controller_sales_visibility_test.exs
```

Do not rename existing modules.

---

## 6. Proposed Public API Contract

The coding agent should keep this small and explicit.

Recommended functions:

```text
after_attendee_created(event_id, ticket_code, opts \ [])
after_attendees_created(event_id, ticket_codes, opts \ [])
after_attendee_visibility_changed(event_id, ticket_code, opts \ [])
after_attendee_invalidated(event_id, attendee_id, ticket_code, reason_code, opts \ [])
```

Guidance:

```text
Use `after_attendees_created/3` from VS-09B/09C order issuance so a multi-ticket order bumps once, not once per attendee.
Use `after_attendee_invalidated/5` later from VS-15A revocation/refund to append invalidation events if the revocation slice chooses to route through this module.
Do not expose a generic `bump/1` as the main public API; name functions after the domain event so call sites remain understandable.
```

If implementation needs to be even smaller for this slice, start with:

```text
after_attendees_created(event_id, ticket_codes, opts \ [])
```

and add revocation/invalidation support in VS-15A.

---

## 7. Behavior Requirements

### Attendee creation visibility

When Sales creates one or more attendees for an event:

```text
1. The attendee rows are committed.
2. The aggregator is called once for the event and all new ticket codes.
3. `events.event_sync_version` increments once.
4. ETS single-attendee entries for those ticket codes are deleted or replaced.
5. ETS event attendee list is invalidated.
6. Cachex attendee-by-event list cache is invalidated through existing Attendees cache facade.
7. Event stats/occupancy cache is invalidated only if current functions are safe and already used by sync flow.
```

### Idempotency

```text
Calling the aggregator twice for the same already-committed issuance may bump twice; that is acceptable only when the caller genuinely performed two export-affecting transactions.
Issuer code must call it once after the issuance transaction result, not once per ticket.
Tests must catch accidental per-ticket bumping from issuer integration.
```

### Transaction boundary

Preferred pattern:

```text
Repo.transaction(fn ->
  create/reuse attendees
  create/reuse TicketIssues
end)

on success:
  MobileSyncVersionAggregator.after_attendees_created(event_id, ticket_codes)
```

Avoid:

```text
bumping event_sync_version before attendee rows commit
bumping once inside each attendee insert loop
holding external delivery/HTTP work inside transaction
```

### Failure behavior

```text
If cache invalidation fails, log safely and continue after the DB version bump.
If event_sync_version bump fails, return error so the caller can retry or move order to manual review.
Do not partially hide committed attendees by swallowing DB bump failures silently.
```

---

## 8. Mobile Sync Contract Preservation

VS-10 must preserve the existing mobile sync response shape.

Do not change:

```text
GET /api/v1/mobile/attendees
required `limit` parameter
attendees array shape
invalidations array shape
event_sync_version field
cursor behavior
since behavior
scanner token authentication
```

New Sales-created attendees should appear because they are normal `attendees` rows with:

```text
event_id
ticket_code
payment_status = "completed" or current scanner-valid equivalent
allowed_checkins
checkins_remaining
scan_eligibility = "active" or nil
updated_at newer than scanner cursor/since boundary
```

---

## 9. Cache Invalidation Rules

### Hot cache: ETS

Use existing ETS helpers where possible:

```text
FastCheck.Cache.EtsLayer.delete_attendee(event_id, ticket_code)
FastCheck.Cache.EtsLayer.invalidate_attendees(event_id)
FastCheck.Cache.EtsLayer.invalidate_event_config(event_id), only if event struct/version is cached and stale reads matter
```

Recommendation:

```text
For multi-ticket issuance, prefer event-level attendee invalidation over many single deletes when ticket count is high.
For one/few tickets, deleting individual attendee keys is acceptable.
Always invalidate the event attendee list cache because mobile/admin list views may otherwise miss new rows.
```

### Warm cache: Cachex

Use the existing public facade:

```text
FastCheck.Attendees.invalidate_attendees_by_event_cache(event_id)
```

Do not directly construct Cachex keys in issuer code.

### PubSub

Use PubSub only for existing dashboard/stat channels if already established. Do not invent a new real-time protocol in VS-10.

---

## 10. Tickera Reconciliation Compatibility

Existing reconciliation already calls `Events.bump_event_sync_version!(event_id)`.

VS-10 must not force a rewrite of Tickera reconciliation.

Acceptable options:

```text
Option A: Leave Tickera reconciliation as-is and document it as an existing approved bump path.
Option B: Refactor Tickera reconciliation to call the aggregator only if behavior stays identical and tests prove it.
```

Recommendation:

```text
Choose Option A for MVP. Do not risk regressions in Tickera sync while adding Sales issuance visibility.
```

Required tests:

```text
Existing reconciliation tests still pass.
A full Tickera sync still bumps event_sync_version once.
Sales-origin issuance uses aggregator without changing Tickera reconciliation semantics.
```

---

## 11. RED/GREEN Test Plan

### RED tests first

```text
RED: `FastCheck.Events.MobileSyncVersionAggregator.after_attendees_created/3` does not exist.
RED: calling aggregator after attendee creation increments `event_sync_version` once.
RED: calling aggregator invalidates event attendee list cache.
RED: calling aggregator clears ETS attendee entries for affected event/ticket codes or invalidates event attendees.
RED: multi-ticket issuance calls aggregator once, not once per attendee.
RED: mobile sync-down returns Sales-created attendee after aggregator runs.
RED: incremental mobile sync can see Sales-created attendee because `updated_at` and event version changed.
RED: aggregator failure on DB bump is surfaced to caller.
RED: cache invalidation failure is logged and does not roll back committed attendee state.
RED: existing Tickera reconciliation tests still pass unchanged.
RED: no scanner behavior changes are introduced.
```

### GREEN implementation targets

```text
GREEN: aggregator module exists with explicit domain-named functions.
GREEN: event version increments once per export-affecting call.
GREEN: caches are invalidated through existing public cache modules.
GREEN: VS-09 issuer integration calls aggregator once after successful issuance/linking.
GREEN: mobile sync response shape remains unchanged.
GREEN: scanner tests remain green.
GREEN: reconciliation tests remain green.
```

---

## 12. Required Tests and Suggested Files

Recommended new tests:

```text
test/fastcheck/events/mobile_sync_version_aggregator_test.exs
```

Suggested test groups:

```text
describe "after_attendees_created/3"
describe "cache invalidation"
describe "mobile sync visibility"
describe "issuer integration contract"
describe "Tickera reconciliation compatibility"
describe "boundary creep"
```

Suggested integration test file if VS-09 issuer modules exist:

```text
test/fastcheck/tickets/issuer_mobile_sync_test.exs
```

Suggested mobile test extension:

```text
test/fastcheck_web/controllers/mobile/sync_controller_sales_visibility_test.exs
```

Keep the tests focused. Do not duplicate the entire mobile sync controller suite.

---

## 13. Performance and Scaling Review

### Data layer placement

```text
Hot data: ETS attendee/event caches for scanner lookup and dashboard surfaces.
Warm data: Cachex attendee/event list caches.
Cold data: Postgres events.event_sync_version, attendees, attendee_invalidation_events.
Redis: no new Redis structure in VS-10.
Browser/mobile: mobile app consumes event_sync_version and invalidation feed through existing API.
```

### 100k-user safety

```text
Do not do per-ticket DB event updates for multi-ticket orders.
One `UPDATE events SET event_sync_version = event_sync_version + 1` per committed issuance transaction.
Do not reload all attendees to invalidate cache.
Do not broadcast one PubSub message per ticket.
Do not perform large table scans.
Do not call mobile sync endpoint internally from issuer code.
```

### Cache stampede protection

```text
After invalidation, the next list read may rebuild cache. Existing Cachex/ETS behavior should handle this for MVP.
Do not add complex stampede locks in VS-10 unless current code already has a helper.
For high-volume flash sales, post-payment issuance should batch aggregator calls per order and let mobile scanners paginate normally.
```

### Latency goals

```text
Aggregator DB bump + cache invalidation should be sub-100ms under normal load.
It must not run Paystack, WhatsApp, QR rendering, email, or analytics jobs.
```

---

## 14. Security and Logging Rules

```text
Do not log full ticket codes at info/error level unless current scanner code already treats them as operational identifiers.
Prefer event_id, attendee_id count, ticket_count, correlation_id, and source_channel.
Do not log buyer email/phone.
Do not log delivery tokens, QR tokens, provider payloads, Paystack references, or authorization URLs.
Do not add mobile sync secrets or scanner access codes to logs.
```

---

## 15. Boundary Rules

VS-10 must not implement:

```text
TicketIssue creation
Attendee creation
Paystack verification
WhatsApp delivery
Email delivery
DeliveryAttempt
Refund/revocation workflows
scanner acceptance changes
Android app changes
Redis inventory mutation
new dashboard analytics
```

Allowed integration points:

```text
VS-09B/09C issuer may call aggregator after successful commit.
VS-15A may later call or extend aggregator for revocation/invalidation.
Existing Tickera reconciliation may remain a parallel approved bump path.
```

---

## 16. Failure Modes

| Failure | Required behavior |
|---|---|
| Event row missing | Return `{:error, :event_not_found}` or equivalent; caller moves to retry/manual review. |
| DB bump fails | Surface error; do not silently continue. |
| Cachex unavailable | Log safely and continue after DB bump. |
| ETS unavailable/uninitialized | Log safely and continue after DB bump. |
| Issuer calls aggregator once per ticket | Tests fail; fix issuer integration. |
| Tickera reconciliation behavior changes | Tests fail; do not ship. |
| Mobile sync response shape changes | Tests fail; do not ship. |
| Scanner logic changes | Tests fail; defer to VS-15A/Android-specific slice. |

---

## 17. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Add the VS-10 Event Sync Version Aggregator to FastCheckin. |
| Objective | Centralize scanner/mobile visibility propagation for Sales-created attendees and future ticket invalidations by bumping `events.event_sync_version` once per committed export-affecting transaction and invalidating existing FastCheck attendee caches safely. |
| Output | New `lib/fastcheck/events/mobile_sync_version_aggregator.ex`; tests in `test/fastcheck/events/mobile_sync_version_aggregator_test.exs`; optional narrow issuer/mobile integration tests if VS-09 modules exist; no mobile API shape changes. |
| Note | Use FastCheckin repo truth. Existing `FastCheck.Events.Event` has `event_sync_version` default `0`; existing `FastCheck.Events.bump_event_sync_version!/1` increments it; existing mobile sync returns `event_sync_version`, attendees, and invalidations; existing `FastCheck.Cache.EtsLayer` caches attendees by `{event_id, ticket_code}` and has event-level invalidation helpers. Keep implementation minimal: explicit functions such as `after_attendees_created/3`, not a vague generic status updater. Call existing cache facades; do not build raw Cachex keys in issuer code. Hot layer: ETS; warm layer: Cachex; cold layer: Postgres. No Redis structure in this slice. Bump once per order/transaction, not once per ticket. Preserve Tickera reconciliation behavior. No scanner acceptance changes, no Attendee creation, no TicketIssue creation, no Paystack, no WhatsApp, no DeliveryAttempt, no Redis inventory mutation. Required tests: one bump per multi-ticket issuance, cache invalidation, mobile sync visibility, existing reconciliation tests green, scanner tests green, log redaction. |
| Success | Sales-created attendees become visible to mobile scanners through the existing sync-down pathway after one version bump and cache invalidation, without changing scanner logic or mobile response contracts. |

---

## 18. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-10 — Event Sync Version Aggregator in the FastCheckin repo.

Use the existing FastCheckin code as truth:
- Event schema: `FastCheck.Events.Event`
- Event version field: `event_sync_version`
- Existing bump helper: `FastCheck.Events.bump_event_sync_version!/1`
- Existing attendee schema: `FastCheck.Attendees.Attendee`
- Existing ETS cache: `FastCheck.Cache.EtsLayer`
- Existing attendee cache facade: `FastCheck.Attendees.invalidate_attendees_by_event_cache/1`
- Existing mobile sync endpoint: `FastCheckWeb.Mobile.SyncController.get_attendees/2`
- Existing Tickera reconciliation: `FastCheck.Attendees.Reconciliation.apply_after_authoritative_snapshot/3`

Task:
1. Add `lib/fastcheck/events/mobile_sync_version_aggregator.ex`.
2. Implement a minimal explicit API, starting with `after_attendees_created(event_id, ticket_codes, opts \ [])`.
3. On successful call, bump `event_sync_version` once for the event.
4. Invalidate affected ETS attendee entries or event-level attendee cache.
5. Invalidate Cachex-backed event attendee list through existing public cache facade.
6. Return `:ok` or a clear `{:error, reason}`.
7. Add tests proving multi-ticket issuance causes one event version bump, not one per attendee.
8. Add tests proving mobile sync can see Sales-created active attendees after aggregator runs.
9. Keep existing Tickera reconciliation and scanner tests green.

Do not:
- change the mobile sync response shape
- change scanner acceptance logic
- create Attendees
- create TicketIssue rows
- call Paystack
- send WhatsApp/email
- create DeliveryAttempt records
- mutate Redis inventory
- introduce broad PubSub protocols
- perform one DB bump per ticket in a multi-ticket order
- log PII, tokens, scanner secrets, or provider payloads

Performance requirements:
- one DB update per event-changing transaction
- no large table scans
- no external HTTP
- no cache-key construction outside existing cache modules unless unavoidable
- safe under flash-sale post-payment issuance bursts
```

---

## 19. Human Review Checklist

```text
[ ] New aggregator module exists under `lib/fastcheck/events/`.
[ ] Public API is explicit and domain-named.
[ ] Multi-ticket order causes one event version bump.
[ ] Cache invalidation uses existing ETS/Attendees cache helpers.
[ ] No raw Cachex keys are duplicated in issuer code.
[ ] Mobile sync response shape unchanged.
[ ] Sales-created active attendee appears in mobile sync-down after aggregator call.
[ ] Existing `FastCheck.Attendees.ReconciliationTest` still passes.
[ ] Existing scanner tests still pass.
[ ] No Paystack/WhatsApp/DeliveryAttempt/Redis inventory behavior added.
[ ] Logs are PII/token safe.
[ ] Final report states where VS-09B/09C issuer should call the aggregator.
```

---

## 20. Next Slice

```text
VS-11 — Secure Ticket Page
```
