---
trigger: always_on
---

Respect the current architecture: Phoenix backend with existing contexts (Events, Attendees, CheckIns, etc.) plus a separate Svelte mobile client.

Do not merge or blur domain boundaries (e.g. do not put attendee domain logic inside controllers).

Mobile API endpoints must live under /api/mobile and use a dedicated pipeline; do not mix them into browser/LiveView routes.

The backend remains the single source of truth for ticket state. The mobile client is an offline/cache layer, not a new authority.