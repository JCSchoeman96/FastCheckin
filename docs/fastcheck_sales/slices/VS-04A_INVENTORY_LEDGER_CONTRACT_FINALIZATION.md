# VS-04A Inventory Ledger Contract Finalization

## Status

Approved contract-finalization slice (docs-only).

## Purpose

Finalize one implementation-ready inventory ledger contract before runtime work
starts in VS-04B and VS-04C.

## Authority

- Primary authority: `docs/fastcheck_sales/inventory/INVENTORY_MASTER_CONTRACT.md`
- Supporting detail docs: `docs/fastcheck_sales/inventory/*.md`
- If any detail doc conflicts with the master contract, the master contract
  wins.

## Finalized Contract Surface

- Redis key contract for inventory, holds, hold detail, lock, dedupe, event
  trail, and event-offer cache families.
- `ReservationLedger` operation family:
  - `reserve/5`
  - `consume/4`
  - `release/3`
  - `expire_due_holds/1`
  - `get_availability/1`
  - `reconcile_offer/1`
  - `mark_offer_degraded/2`
  - `mark_offer_healthy/1`
- Tagged result envelope and explicit error families.
- Idempotency and per-order lock behavior.
- Hold TTL/expiry policy and payment-after-expiry inventory outcomes.
- Degraded/fail-closed behavior and restart/recovery constraints.
- Deterministic reconciliation precedence (`Postgres/Ash` durable state wins).
- Cache/PubSub invalidation rules and non-PII payload constraints.
- VS-04B/VS-04C RED/GREEN implementation test expectations.

## Boundaries Preserved

- No runtime code changes.
- No Ash resource/migration/config/worker/router/controller/liveview changes.
- No Paystack, Meta/WhatsApp, ticket issuance, scanner, attendee, or mobile
  runtime changes.

## Dependencies Reused

- Accepted decision docs: VS-00A, VS-00B, VS-00C, VS-00D.
- Merged handoffs: VS-01B, VS-01G, VS-03.

## Follow-up

The VS-04A implementation handoff document is created only after the VS-04A
contract PR is merged, in a separate docs-only post-merge handoff PR.
