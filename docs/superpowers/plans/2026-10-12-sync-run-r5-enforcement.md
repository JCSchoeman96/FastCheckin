# SyncRun R5 enforcement implementation plan

> **For agentic workers:** Use the required test-first workflow for every production change. Track each step with the checkboxes below.

**Goal:** Enforce one active SyncRun per Event and complete ownership fields in PostgreSQL, while removing public Event-ID-only start and reset paths.

**Architecture:** Add separate forward-only migrations for the partial unique index and active ownership CHECK constraint, preserving nullable ownership for terminal history. Keep `SyncRunner` and caller-supplied authority guards as the only production sync start path, and keep shared credential helpers used by `SyncRunner`.

**Tech Stack:** Elixir, Phoenix, Ecto, PostgreSQL, ExUnit, Mix, GitHub CLI.

---

## Authority and fixed scope

This plan implements only R5 of `docs/fastcheck_sales/development/BROWSERAUTH_EVENT_ISOLATION_REMEDIATION_PLAN.md`, authority version 1.4 / FROZEN. That document defines lifecycle semantics and remains authoritative. This plan does not change R0–R4 semantics, begin R6, modify PR #514, deploy, or merge.

Production migration preflight is a deployment requirement, not an implementation-time production query. Before either R5 migration runs in production, inspect duplicate active runs per Event, each required ownership field on active rows, expired active rows, and active rows inconsistent with Event status. Unexpected active data must stop deployment with `STOP=MIGRATION_ACTIVE_RUN_RECONCILIATION_REQUIRED`; do not clean or repair production rows in these migrations.

Performance decisions are fixed by v1.4: Postgres remains durable ownership authority; `SyncState` remains hot state; no Redis ownership or distributed locks; retain `sync_logs_active_lease_expiry_index`; add a partial unique `event_id` index only for `in_progress` and `paused`; leave lease TTL, cache TTL, cache invalidation, and PubSub behavior unchanged.

## Files and responsibilities

- `test/fastcheck/events/sync_run_r5_enforcement_test.exs`: exercise real PostgreSQL uniqueness and CHECK constraints, terminal history compatibility, and public API exports.
- `priv/repo/migrations/<timestamp>_add_sync_run_active_unique_index.exs`: create and reverse the named partial unique index concurrently.
- `priv/repo/migrations/<timestamp>_add_sync_run_active_ownership_constraint.exs`: add and validate the named active ownership CHECK constraint without global NOT NULL changes.
- `lib/fastcheck/events.ex`: remove public unguarded `sync_event` and Event-ID-only `force_reset_sync` delegates.
- `lib/fastcheck/events/sync.ex`: retain shared helpers needed by `SyncRunner`; make legacy executor and Event-ID-only lifecycle operations unreachable or remove them.
- `test/fastcheck/events/sync_test.exs`, `test/fastcheck/integration/end_to_end_test.exs`: move meaningful existing sync coverage to the guarded runner with explicit test-only authority functions.
- Existing SyncRun regression tests: modify only if the focused R5 suite identifies a missing requirement.

## Task 1: Write R5 database enforcement tests first

- [ ] Add database tests for duplicate `in_progress` and duplicate `paused` rows on one Event being rejected, a terminal row sharing an Event with an active row being allowed, and a valid owned active row being accepted.
- [ ] Test each NULL ownership field independently on active rows: `sync_run_id`, `owner_token`, `heartbeat_at`, and `lease_expires_at`.
- [ ] Test terminal rows with NULL ownership fields remain insertable, including `completed`, `failed`, and `cancelled` states.
- [ ] Test public exports for `FastCheck.Events.sync_event/*`, `FastCheck.Events.force_reset_sync/*`, and any remaining legacy lifecycle entry points in `FastCheck.Events.Sync`.
- [ ] Run `scripts/with-test-db-env.sh mix test test/fastcheck/events/sync_run_r5_enforcement_test.exs` and confirm the missing database constraints cause the expected failures.

## Task 2: Add partial active-run uniqueness migration

- [ ] Choose and record unused migration timestamps after reviewing current migrations.
- [ ] Add `sync_logs_one_active_run_per_event_index` as a partial unique index on `event_id` for statuses `in_progress` and `paused`, with concurrent creation and migration transaction/lock settings supported by this repository's Ecto version.
- [ ] Provide a reversible rollback that drops the same index concurrently.
- [ ] Do not edit the R0 expansion migration or the existing lease recovery index migration; do not include row cleanup.
- [ ] Run the focused database test and migration forward/rollback on a disposable test database.

## Task 3: Add active ownership CHECK migration

- [ ] Add `sync_logs_active_ownership_fields_check` using `CHECK (...) NOT VALID`, followed by validation.
- [ ] Require all four ownership fields only for `in_progress` and `paused`; allow NULL ownership in terminal history.
- [ ] Do not backfill ownership or make columns globally NOT NULL.
- [ ] Run the focused database test and migration forward/rollback on a disposable test database.

## Task 4: Remove legacy Event-ID-only public lifecycle APIs

- [ ] Remove the public `FastCheck.Events.sync_event/*` delegate and `FastCheck.Events.force_reset_sync/*` delegate.
- [ ] Preserve the two production guarded callers in `DashboardLive` and `ScannerPortalLive` unchanged.
- [ ] Keep only shared helper functions in `FastCheck.Events.Sync` that `SyncRunner` still needs. Remove or privatize legacy executor and force-reset paths so production code cannot call them.
- [ ] Migrate meaningful `sync_test.exs` and `end_to_end_test.exs` coverage to the guarded runner with an explicit test-only authority guard. Add no production allow-all guard.
- [ ] Verify the new API-export assertions fail before removal and pass after removal.

## Task 5: Confirm R5 concurrency and owner-fencing coverage

- [ ] Review existing SyncRun, control, heartbeat, recovery, and runner tests against the frozen requirements: database rows remain unique under concurrent claims; stale owners cannot mutate or terminalize; paused remains active; terminalization frees uniqueness; expired takeover stays serialized; recovery cannot terminalize a renewed lease; authority loss stops HTTP and owner writes.
- [ ] Add only missing focused regressions; reuse existing tests otherwise.
- [ ] Run all required SyncRun test files and affected legacy/integration tests through `scripts/with-test-db-env.sh`.

## Task 6: Verify, review, and prepare PR

- [ ] Run focused R5 tests, existing SyncRun regression files, migrated legacy/integration tests, formatting, compile with warnings as errors, `mix precommit`, and `git diff --check`.
- [ ] Confirm migrations apply and roll back on a disposable database, and inspect the final diff for untouched R0 migration/index, guarded production callers, unchanged timings, and no Redis ownership.
- [ ] Review exact branch commits for signed history. Push the R5 branch, open a PR against `main`, register its URL with the T3 thread, and wait for exact-head CI. Do not merge or deploy.
- [ ] Report PR #514 state and head again; make no changes to it.
