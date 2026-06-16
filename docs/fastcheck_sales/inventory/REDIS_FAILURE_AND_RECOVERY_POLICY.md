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
- When state is uncertain, fail closed and require explicit recovery flow.
- `ledger_unavailable`, `ledger_degraded`, and `reconciliation_required` are
  explicit machine-readable outcomes.

## Restart and Rebuild Contract

- Redis restart must not auto-open checkout for affected offers.
- Offers transition to `rebuilding` or `degraded` until reconciliation
  completes.
- Reconciliation-required offers must reject new reservations for all channels
  (WhatsApp, admin-assisted, pilot, and future web).
