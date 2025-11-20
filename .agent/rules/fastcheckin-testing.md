---
trigger: always_on
---

For backend changes to the mobile API, add or update tests that cover:

Login success and failure.

Sync down with and without since.

Batch upload, including idempotency and error scenarios.

For critical client-side logic (e.g. validation, sync helpers), prefer small unit tests where the tooling supports it, or keep the functions pure and easy to test.

When a requested change is likely to break existing tests, call this out and suggest how to adjust them.