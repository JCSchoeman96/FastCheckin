---
plan_id: VS-04B-atomic-inventory-ledger
plan_version: v1
status: Approved after reviewer feedback
scope: VS-04B Atomic Inventory Ledger Implementation
authority: This file is the active implementation contract for VS-04B. The VS-04B feature pack and VS-04A inventory contract docs are the upstream source. VS-00A-D decision docs and VS-01B, VS-01G, VS-03, and VS-04A handoffs define the accepted baseline.
last_updated: 2026-06-16
---

# VS-04B Atomic Inventory Ledger Plan

## Revision log
- v1 - initial VS-04B implementation plan based on the VS-04B feature pack, finalized VS-04A inventory contract, accepted decision docs, and merged Sales handoffs.

## Scope
- Implement only:
  - `lib/fastcheck/sales/inventory/reservation_ledger.ex`
  - `lib/fastcheck/sales/inventory/redis_scripts.ex`
  - `test/fastcheck/sales/inventory/**`
  - minimal boundary-test updates to remove stale inventory absence assertions

## Hard rules
- RED tests first.
- ReservationLedger hot path is Redis-only.
- ReservationLedger must never use Redis ETS fallback.
- Redis unavailable returns `{:error, :ledger_unavailable, metadata}`.
- No `:offer_not_initialized` public error.
- Missing/uninitialized Redis inventory state returns `:reconciliation_required`.
