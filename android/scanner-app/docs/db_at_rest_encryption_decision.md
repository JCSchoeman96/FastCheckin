# DB-at-Rest Encryption Decision

## Status

Proposed decision record for Priority 5.1.

## Context

Current Android scanner runtime posture:

- session JWT is already stored in encrypted preferences via session vault
- Room stores operational runtime state including:
  - attendees
  - queued scans
  - local admission overlays
  - quarantined scans
  - replay and flush runtime surfaces
  - sync metadata

Priority 5.1 focuses first on making retention semantics explicit and tested.

## Risk Assessment

- **Lost/stolen device risk:** Room contents are readable at rest if device-level
  protections are bypassed.
- **Operational risk:** queue durability is critical; unsafe DB migration can
  cause field data loss or upload regressions.
- **Support risk:** encrypted-Room rollout increases startup/migration
  complexity and support burden during active scanner stabilization.

## Decision

Do not implement Room encryption in this Priority 5.1 slice by default.

Keep DB-at-rest encryption gated behind explicit deployment-policy approval after:

1. retention and session-boundary behavior is fully stabilized
2. migration and rollback strategy is reviewed
3. queue durability tests for upgrade path are in place

## If Approval Is Granted Later

Required implementation gate:

- add encrypted Room integration in a dedicated PR
- include migration tests from unencrypted -> encrypted schema
- include startup-open tests on upgraded databases
- include queue durability verification across upgrade and rollback paths
- define operational recovery runbook for failed migration
