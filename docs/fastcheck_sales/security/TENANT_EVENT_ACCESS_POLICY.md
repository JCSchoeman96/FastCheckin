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
