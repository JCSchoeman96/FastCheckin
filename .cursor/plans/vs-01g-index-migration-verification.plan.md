# VS-01G Index and Migration Verification Implementation Plan

Plan ID: VS-01G-index-migration-verification
Plan version: v1
Status: Approved after reviewer feedback
Scope: VS-01G Index and Migration Verification
Authority: This file is the active implementation contract for VS-01G. The VS-01G feature pack is the upstream source. VS-01B through VS-01F handoffs define merged implementation reality.
Last updated: 2026-06-15

Revision log:
- v1 - initial VS-01G implementation plan based on VS-01F handoff and VS-01G feature pack.

## Summary

Implement exactly VS-01G by adding verification coverage and documentation for
the current FastCheck Sales database foundation. This slice verifies existing
Sales migrations, DB-level indexes, partial unique indexes, foreign keys,
Ash identity alignment, duplicate/idempotency constraints, migration
reversibility, and forbidden runtime boundaries.

Default: do not rewrite existing migrations. Only add a new corrective
migration if a RED test proves a missing DB fact. Do not modify old migration
files unless the maintainer explicitly confirms these migrations have not been
shared or applied anywhere outside local development.

## Files

- Create `test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs`
  for the full VS-01G database/index/identity/boundary contract.
- Create `docs/fastcheck_sales/slices/VS-01G_INDEX_AND_MIGRATION_VERIFICATION.md`
  for the slice result, migration review, performance posture, and boundaries.
- Create this canonical plan file.
- Do not change `lib/fastcheck/sales/*.ex` unless identity tests prove a real
  mismatch.
- Do not add a migration unless a RED test proves a missing DB index,
  constraint, or FK.

## Implementation Tasks

1. Add a VS-01G migration/index test module using `FastCheck.DataCase`.
2. Verify the complete ten-table Sales inventory through VS-01F.
3. Verify every required query-path index by catalog fact: index name, ordered
   columns, uniqueness, and partial predicate where applicable.
4. Verify nullable uniqueness precisely:
   - `sales_payment_events(provider, provider_event_id)` is partial unique
     where `provider_event_id IS NOT NULL`.
   - `sales_payment_events(provider, payload_hash)` is partial unique where
     `provider_event_id IS NULL`.
   - `sales_ticket_issues(ticket_code)` is partial unique where
     `ticket_code IS NOT NULL`.
5. Verify required relationship foreign keys and document accepted non-FK
   relationships.
6. Verify critical Ash identities and AshPostgres identity index names align
   with DB unique indexes.
7. Add direct duplicate insert tests for critical idempotency and uniqueness
   constraints.
8. Add no-tenant/no-runtime-boundary regression assertions.
9. Create the VS-01G slice documentation.
10. Run focused and full verification commands.

## Forbidden Scope

Do not add Sales resources, workflow actions, generic `update_status` or
`update_state`, checkout behavior, Paystack, Redis, WhatsApp/Meta, ticket
issuance, QR/token generation, Oban workers, routes, controllers, LiveViews,
scanner, attendee, event, mobile, Android changes, `organization_id`, broad raw
payload indexes, or dependency upgrades.

## Verification

Run:

- `mix deps.get`
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs`
- `mix test test/fastcheck/sales/`
- `mix test`
- `mix precommit`

Run rollback/migrate review if feasible for the local test DB:

- `MIX_ENV=test mix ecto.rollback -n 1`
- `MIX_ENV=test mix ecto.migrate`
