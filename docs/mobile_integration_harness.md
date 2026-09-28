# Mobile Integration Harness

This runbook defines the deterministic Phoenix + Android integration harness for
scanner runtime lifecycle validation.

## Purpose

Validate end-to-end runtime truth for active and revoked/refunded ticket
transitions using:

- real Phoenix `/api/v1/mobile/*` APIs
- seeded deterministic event data
- Android connected tests
- DataWedge-style ticket injection (no camera dependency in v1)

## Environment model

The harness runs in a scripted, project-isolated perf environment:

- infra: `postgres`, `redis`, `pgbouncer`, and the one-shot `perf-db-role`
  service from the explicit `docker-compose.yml` `perf-small` profile
- Compose project: `fastcheckin` by default (override with
  `PERF_COMPOSE_PROJECT`)
- backend runtime: `MIX_ENV=perf`
- database: `fastcheck_prod` on the dedicated perf PostgreSQL at
  `127.0.0.1:5434`, using the non-superuser `fastcheck_perf` role
- Android connected tests with instrumentation args that enable integration mode
  in androidTest dependency wiring

The harness never uses workstation `dev-core` services or the shared DEV
database. Migrations use the perf stack's admin URL; application and cleanup
commands use `fastcheck_perf`.

The runner controls ordering and mutation. Android instrumentation does not
perform backend state mutations.

## One-command run

Run from repo root:

```bash
bash scripts/integration/run-mobile-integration-harness.sh
```

Optional environment overrides:

- `ATTENDEES` (default `40`)
- `CREDENTIAL` (default `scanner-secret`)
- `TICKET_PREFIX` (default `INTEG`)
- `MANIFEST_PATH`
- `ARTIFACT_DIR`
- `REVOKE_REASON` (default `revoked`)
- `KEEP_SEEDED_DATA=true` to keep seeded data for manual debugging

Required perf-stack credentials:

- `FASTCHECK_PERF_DB_PASSWORD` for the non-superuser application role
- `PERF_ADMIN_DB_PASSWORD` for the disposable perf PostgreSQL admin role
- `SECRET_KEY_BASE`, `ENCRYPTION_KEY`, and `MOBILE_JWT_SECRET` for the
  `MIX_ENV=perf` runner

Current scripted scope:

- wired: active -> revoked/not-scannable convergence
- not yet wired in this one-command flow: payment-status mutation scenario
  (tooling exists and can be run manually)

## Runner sequence (strict)

1. boot the explicit `docker-compose.yml` stack with project name
   `fastcheckin` and profile `perf-small`
2. migrate the existing perf database through its admin URL
3. seed deterministic event and known ticket set
4. start Phoenix server
5. wait for backend readiness
6. run connected phase 1 (`activeTicketIsAcceptedAfterLoginAndSync`)
7. mutate backend in outer runner (`fastcheck.load.revoke_mobile_ticket`)
8. dump scenario state (`fastcheck.load.dump_mobile_ticket_state`)
9. run connected phase 2 (`mutatedTicketIsRejectedAfterResync`)
10. collect artifacts

Important artifact:

- post-mutation scenario dump is written to
  `post-mutation-ticket-state.json` in the harness artifact directory.

## Scenario state dump contract

`MIX_ENV=perf mix fastcheck.load.dump_mobile_ticket_state` emits JSON with at
least:

- `event_id`
- `ticket_code`
- `attendee_id`
- `scan_eligibility`
- `payment_status`
- `event_sync_version`
- `invalidations[]` with `id`, `change_type`, `reason_code`, `effective_at`

## Backend mutation commands

- Revoke:
  - `MIX_ENV=perf mix fastcheck.load.revoke_mobile_ticket --event_id <id> --ticket_code <code>`
- Payment status:
  - `MIX_ENV=perf mix fastcheck.load.set_mobile_ticket_payment_status --event_id <id> --ticket_code <code> --payment_status refunded`
- Dump:
  - `MIX_ENV=perf mix fastcheck.load.dump_mobile_ticket_state --event_id <id> --ticket_code <code>`

All mutation commands are domain-safe and avoid direct SQL state forging.

## Validation gates

Backend:

- `mix test test/fastcheck/load/mobile_integration_scenario_test.exs`

Android:

- connected phase 1 and phase 2 methods in
  `za.co.voelgoed.fastcheck.app.MobileIntegrationHarnessFlowTest`

## Notes on payment-status scenario

Include refund/payment-invalid as a v1 scenario only when current backend
admission logic truly gates admission by payment status for the tested flow.
If that gate is not active for the selected path, focus v1 on
active/revoked/duplicate.
