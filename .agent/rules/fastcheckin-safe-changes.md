---
trigger: always_on
---

Treat check-in, check-out, and attendee state as high-risk areas: be conservative when changing them.

Avoid changing database schema or existing endpoint contracts unless explicitly instructed and backed by a migration/compatibility plan.

When you must make a potentially breaking change, describe the impact and suggest a rollout/testing strategy.