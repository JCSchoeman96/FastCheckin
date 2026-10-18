# Tenant Event Access Policy

## Decision

First release access model:

```text
event_scoped_first
```

Required first-release owner boundary:

```text
event_id
```

Deferred:

```text
organization_id
```

## Rules

- Sales records must be scoped by FastCheck event where the record is
  event-owned or event-derived.
- Admin/operator access must be scoped by event permissions, not by role alone.
- Do not assume all operators can see all Sales records.
- Do not assume dashboards can list all events by default.
- Do not allow unscoped payment, order, ticket, or public-reference lookup.
- Do not add `organization_id` until a later approved tenant-isolation slice
  introduces a real organization model, membership model, policy model, indexes,
  and cross-tenant denial tests.

## Dashboard Sales Grants

The verified current dashboard identity proves who signed in. It does not grant
access to every Event. Effective Event authority requires that identity and
either a configured bootstrap grant or an active durable Postgres grant for
that identity and Event. `FastCheck.Sales.DashboardAccess` resolves this union.

- `DASHBOARD_ALLOWED_EVENT_IDS` is the server-owned bootstrap grant source. A
  missing or blank value grants no Events through configuration; active durable
  grants remain effective.
- A valid configuration is a comma-separated list of positive integer Event
  IDs. IDs are deduplicated and sorted.
- Any nonblank malformed value is a configuration error and prevents startup.
- A durable grant is effective only while its exact dashboard identity and
  Event row is active. Revoked-only history grants no authority. Revoked
  history does not cancel a configured grant for the same Event.
- A database error denies the durable-only grant; a configured grant remains
  effective if the durable lookup fails.
- `DashboardAccess` revalidates the current dashboard identity when it builds
  an actor and when a protected Event operation runs. A stale actor snapshot
  does not preserve a revoked durable grant.
- Browser parameters, LiveView state, and loaded records never supply or widen
  authority. Browser or session state, Redis, ETS, and Cachex are not permission
  sources.
- Sales list and aggregate queries filter by the grant set in SQL/Ash. An Event
  filter can only narrow it. Entity lookups filter by grant before returning
  details; ungranted guessed IDs use the same safe not-found result as missing
  records.
- State-changing Sales services reconstruct authority from the authenticated
  dashboard identity and check the requested Event against the current
  configured and durable grants before existing transition, lock, inventory,
  and worker logic.
- `DashboardAccess.actor_for_identity/1` is the dashboard identity-to-Sales
  actor constructor. Callers may not manufacture event grants from route or
  record IDs.

P1-D applies this boundary to the dedicated Sales dashboard, operations,
audit, manual review, order/refund/revocation, admin ticket PDF, secondary
checkout, Event overview, WhatsApp offer management, and the Sales-specific
WhatsApp controls in the root dashboard.

The production Sales dashboard has one configured admin identity. AdminRevocations resolves that identity through DashboardAccess and uses server-owned Event grants. No authenticated production Sales operator entry point exists. Core :operator support does not authenticate a caller or establish grant provenance. Do not treat actor maps, scanner names, or shared scanner credentials as Sales operator authority. Track trusted operator identity and Event binding as FastCheckin-iuaq.

## BrowserAuth Event isolation

P1-D covers Sales-owned consumers. The root dashboard's general Event
administration and sync operations, CSV attendee/check-in exports, BrowserAuth
scanner, and occupancy views use the same current dashboard Event-grant union
through their BrowserAuth isolation checks. P1-D does not establish that
broader boundary. ScannerAuth and the Android `/api/v1/mobile/*` contract remain
separate and do not use dashboard Event grants.

## Future Organization Isolation

Docs and implementation should leave room to add `organization_id` later:

- Avoid module, policy, and index names that imply one deployment equals one
  organization.
- Avoid hard-coded assumptions that one operator owns every event.
- Keep event access checks explicit and testable.

## Future Tests

- Admin/operator list actions deny cross-event records.
- Admin/operator read actions deny cross-event records.
- Manual actions deny cross-event records.
- Customer sessions can access only token/session/order-scoped records.
