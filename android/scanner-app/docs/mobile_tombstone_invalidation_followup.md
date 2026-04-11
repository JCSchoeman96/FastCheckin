# Mobile API: tombstone / invalidation follow-up (contract track)

## Problem

The current `GET /api/v1/mobile/attendees` contract is upsert-oriented. The
Android scanner can refresh and replace local rows, but it cannot reliably
converge when tickets are **deleted**, **revoked**, or **superseded** on the
server unless a full attendee pull is scheduled or a future invalidation feed
exists.

## Desired backend capabilities (future)

- Cursor- or version-scoped **tombstone** or **invalidation** entries (ticket id
  or normalized ticket code + event id + reason + effective time).
- Clear semantics for incremental sync: apply upserts, then apply tombstones in
  order, without requiring a full list download on every tick.

## Android posture until promoted

- Keep using `/api/v1/mobile/*` only.
- Rely on **full reconcile** (atomic per-event attendee replace + metadata) on
  integrity failure thresholds, time since last full reconcile, and incremental
  cycle counts, as implemented in `DefaultAttendeeSyncOrchestrator` and
  `CurrentPhoenixSyncRepository`.
- Do not couple the scanner to future `/api/v1/check_ins` or device-session
  routes until the backend formally promotes a new contract.

## Conflict taxonomy (documentation-only for now)

Future cross-device reconciliation should classify outcomes consistently:

- Duplicate confirmed elsewhere
- Revoked after snapshot
- Invalid code
- Transient upload rejection
- Terminal support-required

## References

- `docs/mobile_runtime_truth.md` — runtime contract boundaries
- `android/scanner-app/docs/architecture.md` — layer map and authority split
