# Redis Failure and Recovery Policy

## Failure Matrix

| Failure | Required behavior |
|---|---|
| Redis unavailable during checkout | Do not accept new reservations; show temporary unavailable/manual review. |
| Redis unavailable after payment verification | Do not blindly issue; retry safe consume or move to manual review depending known hold state. |
| Redis restarts and loses volatile holds | Close/degrade affected offers; rebuild/reconcile from Postgres before reopening. |
| Redis says available but durable facts disagree | Durable issued-ticket/order facts win; reconcile Redis downward. |
| Postgres order awaiting payment but Redis hold missing | Apply checkout expiry/payment-after-expiry policy. |
| Duplicate release/consume after retry | Idempotent and safe. |
| Expiry worker runs late | Expire only still-active holds; never release consumed holds. |
| Reconciliation detects negative availability | Mark unhealthy/manual review; do not continue sales. |
| Reconciliation detects orphaned holds | Release, expire, or manual-review by durable state. |

## Rules

- No flash-sale checkout proceeds while inventory ledger health is unknown.
- Rebuild/reconcile must not reopen sales until health is explicitly `healthy`.
- Redis recovery must produce a reconciliation report.
- Manual Redis intervention during live sale requires runbook and audit.
