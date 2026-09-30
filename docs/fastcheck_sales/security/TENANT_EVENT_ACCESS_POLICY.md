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

The authenticated dashboard identity proves who signed in. It does not grant
access to every Event. Sales access uses the server-owned
`DASHBOARD_ALLOWED_EVENT_IDS` allowlist, resolved by
`FastCheck.Sales.DashboardAccess`.

- Missing or blank configuration grants no Sales Events.
- A valid configuration is a comma-separated list of positive integer Event
  IDs. IDs are deduplicated and sorted.
- Any nonblank malformed value is a configuration error and prevents startup.
- Browser parameters, LiveView state, and loaded records never supply or widen
  the grant set.
- Sales list and aggregate queries filter by the grant set in SQL/Ash. An Event
  filter can only narrow it. Entity lookups filter by grant before returning
  details; ungranted guessed IDs use the same safe not-found result as missing
  records.
- State-changing Sales services reconstruct authority from the authenticated
  dashboard identity and check the requested Event against its configured
  grants before existing transition, lock, inventory, and worker logic.
- `DashboardAccess.actor_for_identity/1` is the dashboard identity-to-Sales
  actor constructor. Callers may not manufacture event grants from route or
  record IDs.

P1-D applies this boundary to the dedicated Sales dashboard, operations,
audit, manual review, order/refund/revocation, admin ticket PDF, secondary
checkout, Event overview, WhatsApp offer management, and the Sales-specific
WhatsApp controls in the root dashboard.

## Separate BrowserAuth Event-Isolation Work

P1-D does not establish application-wide event isolation. The root dashboard's
general Event administration and sync operations, CSV attendee/check-in
exports, browser scanner, and occupancy views remain outside the Sales grant
boundary. Track those authenticated surfaces in a separate BrowserAuth
event-isolation security slice. Do not describe P1-D as closing that broader
access gap.

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
