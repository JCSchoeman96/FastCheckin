# FastCheck shared workstation infrastructure migration plan

## Approved contract

- Workstation PostgreSQL 18 DEV: `127.0.0.1:55432`, database/role `fastcheck_dev`.
- Workstation PostgreSQL 18 TEST: `127.0.0.1:55433`, base database/role `fastcheck_test`.
- Preserve the existing `MIX_TEST_PARTITION` convention by appending its value to `fastcheck_test`.
- Workstation Redis 7 DEV/TEST: `127.0.0.1:56379` and `127.0.0.1:56380`.
- Project code does not create, start, stop, recreate, or delete the workstation shared services.
- PostgreSQL app roles are non-superuser. TEST may have `CREATEDB` on the dedicated TEST cluster; PostgreSQL does not restrict that privilege by database-name prefix.
- Redis keys include project and environment scope; tests use a unique per-run TEST namespace. No code issues `FLUSHALL` or `FLUSHDB` against shared Redis.
- Performance/load PostgreSQL and Redis remain in the existing project-isolated Compose stack.
- The canonical root `compose.yaml` deploys the Phoenix application and does not define workstation PostgreSQL or Redis.
- Existing legacy containers, databases, and volumes are preserved; the workstation `dev-core` stack is untouched.

## Implementation tasks

1. Configure development and test PostgreSQL endpoints, allocated names and roles, and direct connections. Reject test configuration that targets the locked DEV endpoint. Keep the partition suffix exactly as it is today. Set the supported PostgreSQL baseline and CI service to PostgreSQL 18.
2. Centralize Redis project/environment key scoping. Apply it to all production Redis key builders and test cleanup/query patterns. Give each test process a distinct Redis prefix. Remove the `FLUSHDB` cleanup path and retain targeted cleanup within the test prefix.
3. Add root `compose.yaml` for the independently deployable Phoenix application only. Keep the existing performance Compose stack project-isolated and explicitly documented as opt-in.
4. Update development, integration-harness, deployment, environment-template, and performance documentation/scripts so ordinary development and tests use the externally owned workstation services without starting/stopping them. Exclude local secret files from Docker build context.
5. Validate configuration and Compose, create a disposable clean database only on the TEST cluster for PostgreSQL 18 migrations, run the approved DEV migration, prove application database queries and health, verify DEV/TEST isolation, exercise Redis namespace safety, run the full relevant suite and repository gates, inspect secret exposure and confirm the legacy infrastructure remains intact.

## Guardrails

- Do not run `docker compose up`, `down`, `restart`, `rm`, or volume/database deletion against `dev-core` or the legacy performance stack.
- Never reset or drop the existing DEV database during validation. Run DEV migrations only when explicitly authorized.
- Do not change the existing performance Redis/PostgreSQL topology or delete its data.
- Do not commit runtime secrets or local passwords.
- Report any validation that cannot be completed without modifying existing infrastructure.

## Final closure verification

The pre-migration baseline is commit `5d5adf0e92ea3fa423e174c86c33887d706ce90c`. The candidate and a detached worktree at that commit were compiled with the same Elixir/OTP toolchain and checked with `mix dialyzer_check`. Both report 62 findings. Comparing warning file, kind, and diagnostic text found zero added findings, zero removed findings, and no candidate-only finding. The Dialyzer failure predates this migration and remains separate remediation work.

For handoff, the migration commit was rebased onto current `main` at `bf33559eb991a671059bc607bfa75e8a269b4152`. That baseline reports 60 findings. The rebased candidate also reports 60; comparing warning file, kind, and diagnostic text found zero added findings, zero removed findings, and no candidate-only finding.

The authorized DEV migration command applied the five migrations added after the earlier validation. `mix ecto.migrations` confirmed all 52 migrations are up on `fastcheck_dev`; a Repo query returned `fastcheck_dev`, `fastcheck_dev`, PostgreSQL 18, and 52 migration rows. Phoenix started through `mix phx.server` with `PORT=4400` because an unrelated Node process already occupied port 4000. After installing the lockfile-pinned packages into ignored `assets/node_modules`, the asset watcher built successfully. `GET /api/v1/health` returned HTTP 200 and `healthy`; its health action executed `SELECT 1` through the Repo. Phoenix emitted a development code-reloader listener warning, but the app remained healthy and the warning did not affect database access.

After rebasing and updating raw Redis-key assertions in the upstream tests, the final `mix precommit` passed with 1,622 tests, zero failures, and four skipped; Credo reported no issues. The focused Redis-related tests passed with 52 tests and zero failures. Tests continue to use the TEST endpoint and preserve the `fastcheck_test` plus `MIX_TEST_PARTITION` database naming convention.

Final `mix sobelow --exit --compact` and `docker compose config -q` checks passed for the canonical and performance Compose files using safe placeholder environment values. The final candidate Dialyzer run still reports 60 findings against 60 on current `main`; normalized diagnostic comparison found zero additions or removals. The gate remains an existing failure. The original pre-migration comparison also remains 62 versus 62 with no delta.

GitHub Actions passed on the final candidate: the Elixir 1.17.3/OTP 26.2 job passed all 1,622 tests, and Harness Readiness compiled Android instrumentation tests successfully. CI provisions its ephemeral TEST role before Mix setup loads configuration. The generated password is masked in workflow logs; the final log scan found no clear value. One intermediate run logged its job-only TEST password before this mask was added; that job completed and its owned database service was torn down.

The repository's local Beads Dolt server has no `FastCheckin` database, so the pre-existing Dialyzer debt could not be entered as a separate Beads item during this pass.

The running legacy performance PostgreSQL container has its primary data directory at `/var/lib/postgresql/18/docker` on an image-created anonymous volume mounted at `/var/lib/postgresql`. The named `fastcheckin_postgres_data` volume is mounted at `/var/lib/postgresql/data`. Do not recreate this performance stack or change its PostgreSQL mount until the existing data location has been backed up and its persistence path migrated deliberately. No workstation `dev-core` or legacy resources were changed. The only temporary service containers were job-owned by GitHub Actions and were stopped by their runners. The workstation inventory remained at 59 containers and 81 volumes, and the pre-existing `fastcheck_test1` database was retained.
