# checked_in_count Audit

This audit was completed before changing `checked_in_count` behavior.

## Decision

- Final intended meaning: count of local attendees for an event with non-`nil` `checked_in_at`
- Occupancy is a separate concept and remains derived from attendee/session state such as `is_currently_inside`
- `checked_in_count` should not remain an actively maintained persisted aggregate
- Read paths that need it should derive it from local attendee data

## Dependency map

| field | current writers | current readers | current meaning per writer | proposed final meaning |
| --- | --- | --- | --- | --- |
| `events.checked_in_count` | `FastCheck.Events.build_event_attrs/2` via `resolve_event_counts/1`; `FastCheck.Events.Stats.get_event_with_stats/1`; `FastCheck.Events.Stats.persist_live_occupancy/2` | `FastCheckWeb.DashboardLive`; `FastCheckWeb.OccupancyLive` via `Events.get_event_with_stats/1`; create-event tests | create: Tickera `checked_tickets`; stats refresh: local attendees ever checked in; live occupancy: current inside count | local attendees with non-`nil` `checked_in_at` |

## Reader review

- Dashboard
  - Directly renders `event.checked_in_count`
  - Safe migration path: compute `checked_in_count` in `Events.list_events/0` from local attendees
- Scanner Live
  - Uses `Attendees.get_event_stats/1` and occupancy breakdown
  - Does not depend on `event.checked_in_count`
- Scanner Portal
  - Uses `Attendees.get_event_stats/1` and occupancy breakdown
  - Does not depend on `event.checked_in_count`
- Occupancy Live
  - Calls `Events.get_event_with_stats/1`, but display metrics come from `Events.get_event_advanced_stats/1`
  - Safe migration path: return an event struct with computed `checked_in_count` without persisting it
- Exports
  - No direct `checked_in_count` read found in active export paths
- Stats and percentages
  - `Attendees.Query.get_event_stats/1` and `compute_occupancy_breakdown/1` already derive check-in and occupancy metrics from attendee rows

## Outcome of audit

- The create-time Tickera writer is semantically wrong for local check-in totals
- The live occupancy writer is semantically wrong because current occupancy is not the same thing as cumulative checked-in attendees
- The attendee-derived read paths are already the dominant source of truth for scanner and occupancy surfaces
- The only dashboard-relevant cache dependency is the event list cache used by `Events.list_events/0`
