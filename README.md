# FastCheck - PETAL Event Check-in System

**Replace Checkinera with a faster, self-hosted alternative.**

FastCheck is a Phoenix + LiveView event check-in system with a separate Kotlin Android scanner app. The backend syncs Tickera data into PostgreSQL and remains the authority for scan acceptance; the Android client is a local-first attendee cache with queued scan uploads.

## Motivation

- Checkinera is hosted WordPress with subscription cost and high per-scan latency.
- FastCheck is self-hosted, designed for high-throughput check-in flows, and keeps your data and workflows under your control.

## What’s in this repo

- **Phoenix app**: LiveView dashboard, browser scanner, scanner portal, CSV exports, and JSON/mobile endpoints.
- **Android scanner app**: `android/scanner-app` (CameraX/ML Kit capture → local queue → WorkManager flush).

## Tech stack (current)

- **Backend**: Phoenix `~> 1.8.1`, Phoenix LiveView `~> 1.1.17`, Elixir `~> 1.17` (see `mix.exs`).
- **Frontend**: LiveView + Tailwind (assets in `assets/`).
- **Data**: PostgreSQL and Redis are external runtime dependencies. Workstation development uses the shared PostgreSQL 18 and Redis 7 services; the opt-in performance stack remains project-isolated in `docker-compose.yml`.
- **Android**: Kotlin, Room, Retrofit/OkHttp, WorkManager (see `android/scanner-app/docs/architecture.md`).

## Active API contract (Android runtime)

These are the only promoted Android runtime endpoints today:

- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

Canonical contract doc:

- `android/scanner-app/CURRENT_PHOENIX_MOBILE_API.md`

Notes:

- The backend is the business-rule authority; the Android app caches + queues and uploads for server decisions.
- Flush status snapshots and their recent outcomes are persisted atomically, so operators see a consistent flush report (not a mixed old/new state) after each update.
- For the promoted hot path, scans are queued locally first, admitted
  authoritatively in backend hot state, queued for durability before
  acknowledgement, and projected into Postgres asynchronously afterward.
- Repo config still falls back to `:legacy` unless runtime overrides it.
  `:redis_authoritative` is the target runtime mode and the mode used by the
  documented authoritative test/perf paths.
- `direction = "out"` is currently not implemented for successful mobile flows (see the contract doc).

Backend runtime note:

- `docs/mobile_runtime_truth.md`

## Architecture boundaries (high-level)

- **Browser/LiveView surfaces** (examples): dashboard, browser scanner, scanner portal, occupancy view (see `AGENTS.md` for the current map).
- **Mobile API**: JWT-protected routes under `/api/v1/mobile/*` (see `lib/fastcheck_web/router.ex`).
- **Legacy/other JSON endpoints**: `/api/v1/check-in` and `/api/v1/check-in/batch` exist behind JWT auth, but are not the promoted Android contract (Android uses `/api/v1/mobile/*`).

## Local development (Phoenix)

### Prerequisites

- Elixir `1.17+`
- Access to workstation `dev-core` PostgreSQL 18 DEV/TEST and Redis 7 DEV/TEST services

Workstation services are externally owned by Dockge's `dev-core` stack. This
repository does not start, stop, recreate, or remove those services.

### Run the app

Copy `.env.development.example` to the ignored `.env.development.local`, set the
FastCheck DEV role password, then export it into the shell:

```bash
cp .env.development.example .env.development.local
set -a
. ./.env.development.local
set +a
mix setup
mix phx.server
```

DEV connects directly to PostgreSQL at `127.0.0.1:55432` using database and role
`fastcheck_dev`, and to Redis at `127.0.0.1:56379`. The database is provisioned
outside this repository; `mix setup` applies migrations and seeds it.

### Run tests

Copy `.env.test.example` to the ignored `.env.test.local`, set the TEST role
password, and export it before running the suite:

```bash
cp .env.test.example .env.test.local
set -a
. ./.env.test.local
set +a
mix test
```

Tests connect only to PostgreSQL at `127.0.0.1:55433` and Redis at
`127.0.0.1:56380`. The TEST database name remains `fastcheck_test` with
`MIX_TEST_PARTITION` appended for partitioned runs. The dedicated TEST role
may have `CREATEDB` on the TEST cluster for this alias; PostgreSQL does not
restrict that privilege to a database-name prefix. It is a non-superuser role
on a separate cluster from DEV.

Health endpoints:

- `GET /api/v1/live`
- `GET /api/v1/health`

### Environment variables

See `.env.example` for the production Compose environment template. It contains
placeholders only; provide real credentials through an ignored env file or
secret manager.

## Local development (Android scanner)

Start here:

- `android/scanner-app/docs/architecture.md`
- `android/scanner-app/CURRENT_PHOENIX_MOBILE_API.md`

Build/run via Android Studio or Gradle in `android/scanner-app/`.

Cross-platform host setup:

- Keep `android/scanner-app/local.properties` untracked and machine-local. Start from `android/scanner-app/local.properties.example`.
- Set `JAVA_HOME` on each machine to a local JDK 25 install. The wrapper uses the host JDK instead of a committed Windows-only path.
- Use `./gradlew` on Linux/macOS and `gradlew.bat` on Windows so each host resolves its own shell and Java path correctly.

Example host setup:

```bash
# Linux
cd android/scanner-app
cp local.properties.example local.properties
# then edit local.properties to point sdk.dir at /home/<you>/Android/Sdk
export JAVA_HOME=/home/<you>/.jdks/jdk-25.0.2+10
./gradlew :app:compileDebugKotlin :app:testDebugUnitTest
```

```powershell
# Windows PowerShell
cd android/scanner-app
Copy-Item local.properties.example local.properties
# then edit local.properties to point sdk.dir at C:\Users\<you>\AppData\Local\Android\Sdk
$env:JAVA_HOME = 'C:\Program Files\Microsoft\jdk-25.0.2.10-hotspot'
.\gradlew.bat :app:compileDebugKotlin :app:testDebugUnitTest
```

## Deployment with Docker Compose

The repository-owned `compose.yaml` is the Phoenix application deployment
contract. It defines the app only and requires external `DATABASE_URL`,
`MIGRATION_DATABASE_URL`, and `REDIS_URL` values. It does not define or manage
workstation DEV/TEST PostgreSQL or Redis. The HTTP port is bound to loopback by
default for a host reverse proxy.

After filling `.env` from `.env.example` with deployment values, validate and
start the app with:

```bash
docker compose -f compose.yaml config
docker compose -f compose.yaml up -d --build
```

Do not run this Compose app beside another FastCheck app process for the same
deployment. The systemd release unit remains the current production lifecycle
configuration until a deployment cutover is made; it is not started by this
repository's local development or Compose validation.

The old `docker-compose.yml` is retained for explicitly isolated performance
work only. Use `-f docker-compose.yml --profile perf-small` when operating that
stack. Its PostgreSQL and Redis services are not workstation shared services
and are not the normal development or test databases.

## Performance testing

The repo includes a k6-based mobile scan performance harness aimed at the authoritative mobile upload path behind `POST /api/v1/mobile/scans`.

- Seed deterministic load data with `mix fastcheck.load.seed_mobile_event`
- Run k6 scenarios from `performance/k6/mobile_scans.js`
- Use `MOBILE_SCAN_FORCE_ENQUEUE_FAILURE=true` only for the dedicated non-production enqueue-failure scenario
- Use `docker compose -f docker-compose.yml --profile perf-small up --build app-perf perf-proxy` for the opt-in capped app-tier path
- Use `mix fastcheck.load.cleanup_mobile_event` to remove seeded perf events and related DB/Redis data after a run
- Hit the trusted perf proxy on `http://127.0.0.1:4100` for `capacity_*` and `abuse_*` runs; `app-perf` stays internal for capacity measurements
- Capacity runs now model `device_i -> token_i -> synthetic_ip_i`, while abuse-control runs intentionally concentrate on one hot device identity

Runbook:

- `docs/mobile_scan_performance.md`
- `docs/mobile_scan_performance_baseline_2026-03-19.md`
- `docs/mobile_runtime_truth.md`
- `docs/pgbouncer_rollout.md`

## Roadmap (high level)
Tracked work now lives in Beads (`bd`).
See `AGENTS.md` for project map and workflow.
See `CONTRIBUTING.md` for contributor workflow.

Now:

- Stabilize and document contributor workflows (dev setup, testing, release steps).
- Keep the Android runtime contract scoped to `/api/v1/mobile/*` and maintain parity with backend serialization.

Next:

- Scanner UX improvements (shortcuts, history, sound feedback).
- Dashboard enhancements (event editing, exports, search/filter).

Later:

- Sync progress improvements (ETA, history/audit log, incremental sync).
- Observability and operational hardening.

## More docs

- `AGENTS.md` (project map + guardrails)
- `docs/INDEX.md` (documentation index)
- `docs/mobile_scan_performance.md` (k6 load, stress, spike, and soak testing)
- `CONTRIBUTING.md` (formatting workflow)
