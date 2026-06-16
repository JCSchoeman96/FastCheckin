# VS-01G Implementation Handoff

## Status

Merged.

PR: #341 — test(sales): verify VS-01G index and migration contract  
Merge commit: `90bb74625be98932286426b328486f3587d94c54`  
Merged at: 2026-06-16T07:14:13Z  
Branch: `vs-01g-index-migration-verification`

## What Changed

VS-01G added verification and documentation for the existing FastCheck Sales
database foundation. It did not change application code, migrations, resources,
runtime behavior, routes, workers, or dependencies.

## Files Changed

- `.cursor/plans/vs-01g-index-migration-verification.plan.md` — canonical
  implementation plan with scope, authority, no-rewrite migration rule, and
  verification checklist.
- `test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs` —
  proves the ten-table Sales inventory, required indexes, partial unique
  predicates, foreign keys, Ash identity/index-name alignment, duplicate insert
  behavior, no `organization_id`, and forbidden runtime boundaries.
- `docs/fastcheck_sales/slices/VS-01G_INDEX_AND_MIGRATION_VERIFICATION.md` —
  documents the verification-only result, relationship decisions, migration
  review, performance posture, security/privacy boundary, and deferred work.

## Contracts Now Available

- The current Sales table inventory is verified as exactly ten tables:
  offers, orders, order lines, checkout sessions, payment attempts/events,
  ticket issues, delivery attempts, conversations, and state transitions.
- Sales tables and resources remain free of `organization_id`.
- Required query-path indexes are guarded by catalog tests for index name,
  ordered columns, uniqueness, and partial predicate.
- DB-level idempotency and uniqueness are guarded for orders, checkout holds,
  payment attempts/events, order lines, ticket codes, ticket line-item
  sequences, and attendee links.
- Required FKs are verified for order lines, checkout sessions, payment
  attempts, ticket issues, delivery attempts, and optional order conversations.
- Accepted non-FK references are documented for `whatsapp_conversation_id`,
  payment event provider references, external `attendee_id`, and polymorphic
  state-transition audit rows.
- Critical Ash identities and AshPostgres `identity_index_names` are verified
  against DB unique indexes.

## Decisions Applied

- `event_scoped_first` remains the first-release access model.
- `organization_id` remains deferred.
- Existing migrations were not rewritten.
- No corrective migration was added because the current schema satisfied the
  new DB assertions.
- Redis remains future-owned hot inventory state; Postgres/Ash remains durable
  Sales truth.
- No workflow actions or generic `update_status` / `update_state` actions were
  added.

## Boundaries Still Enforced

- No checkout workflow, Paystack, Redis inventory, Meta/WhatsApp runtime, ticket
  issuance, QR/token generation, delivery sending, Oban workers, UI, routes,
  controllers, scanner/mobile/Android, attendee, event, or Tickera changes.
- No new Sales resources, migrations, schemas, policies, dependencies,
  `organization_id`, or broad raw payload indexes.

## Tests Added Or Updated

- `test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs` —
  verifies the VS-01G database/index/identity contract and boundary protections.

No existing tests were modified.

## Verification Reported

PR #341 reported:

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs`
  — 6 tests, 0 failures
- `mix test test/fastcheck/sales/` — 89 tests, 0 failures
- `mix test` — 422 tests, 0 failures, 4 skipped
- `mix precommit` — Credo no issues; 422 tests, 0 failures, 4 skipped
- `MIX_ENV=test mix ecto.rollback -n 1 && MIX_ENV=test mix ecto.migrate` —
  latest Sales migration rolled back and reapplied successfully
- Post-rollback targeted rerun:
  `mix test test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs`
  — 6 tests, 0 failures
- GitHub CI `Test (Elixir 1.17.3 OTP 26.2)` — pass

## Known Limitations

VS-01G is verification-only. Later slices still own checkout, payment,
inventory, ticket issuance, delivery, WhatsApp, admin/customer UI, manual
review, attendee protection, scanner behavior, and runtime query paths.

## Next Agent Guidance

Reuse the existing Sales resources, migrations, tables, identities, and index
names. Do not recreate them or bypass the verified DB-level idempotency
constraints.

Keep `test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs`
and the prior Sales skeleton, migration, policy, and boundary tests green when
extending Sales. If a later slice needs a new durable query path, add a narrow
migration and update the relevant tests rather than weakening VS-01G assertions.

Do not introduce `organization_id` until a later accepted tenant-isolation slice
owns that change.

## Next Slice

Recommended next slice: VS-02 — Attendee Origin Protection

Entry condition: VS-01G must remain merged and accepted. The VS-02 agent should
reuse the verified Sales ticket/order/index foundation, keep existing scanner
behavior stable, and avoid migrating legacy Attendees into Ash.
