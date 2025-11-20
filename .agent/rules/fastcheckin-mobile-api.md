---
trigger: always_on
---

All mobile API routes must be under /api/mobile with a :mobile_api pipeline.

Authentication for mobile API uses JWT. All protected endpoints must require and validate the token.

The event_id for mobile operations must always come from the JWT, never from query/body parameters.

Sync endpoints must:

Use JSON only.

Return server_time for sync down.

Accept batches of scans with idempotency_key, ticket_code, direction, and scanned_at for sync up.

Idempotency is enforced via a dedicated table keyed by (event_id, idempotency_key). Duplicate requests must not re-run domain logic.