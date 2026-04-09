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
- **Data**: PostgreSQL (Docker compose uses Postgres 18). Optional pgBouncer + Redis are provided in `docker-compose.yml`.
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
- Docker (recommended for Postgres/pgBouncer/Redis)

### Start infra (recommended)

```bash
# From repo root
docker compose up -d postgres pgbouncer redis
```

Set `DB_PASSWORD` in your environment (or a local `.env`) so compose can seed both Postgres and pgBouncer. For local development you can point `DATABASE_URL` at either:

- Postgres direct: `ecto://postgres:${DB_PASSWORD}@localhost:5434/fastcheck_prod`
- pgBouncer: `ecto://postgres:${DB_PASSWORD}@localhost:6432/fastcheck_prod`

For Redis-backed mobile scan work, the same compose stack publishes Redis on
`redis://localhost:6380` from the host. Container-internal and default env
examples may still use `redis://localhost:6379` (for example `.env.example`
and in-network service wiring).

### Run the app

```bash
mix setup
mix phx.server
```

Health endpoints:

- `GET /api/v1/live`
- `GET /api/v1/health`

### Environment variables

Set `REDIS_URL` explicitly when you are not using the default local Docker
compose port mapping or when production points at a managed Redis host.

See `.env.example` for the full set of production-style env vars. At minimum you’ll need values for `SECRET_KEY_BASE`, `ENCRYPTION_KEY`, `MOBILE_JWT_SECRET`, and `DATABASE_URL` in the environment you run the server under.

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

## Deployment notes (infra + pooling)

- `docker-compose.yml` provides **Postgres 18**, **pgBouncer** (transaction pool mode), and **Redis**.
- pgBouncer is intended to collapse many client connections into a smaller number of upstream Postgres sessions; monitor it with `SHOW POOLS` / `SHOW STATS` via psql.
- Keep the mobile request path unchanged as `validate -> hot-state decision -> enqueue durability -> promote results -> respond`; PgBouncer helps connection pressure and async durability load, not Redis admission semantics.
- Keep `/api/v1/live` as process liveness and `/api/v1/health` as DB-backed readiness/dependency signaling.
- Keep `MIGRATION_DATABASE_URL` pointed at direct Postgres when `DATABASE_URL` points at PgBouncer.
- See `docs/pgbouncer_rollout.md` for the rollout and verification checklist.

## Performance testing

The repo includes a k6-based mobile scan performance harness aimed at the authoritative mobile upload path behind `POST /api/v1/mobile/scans`.

- Seed deterministic load data with `mix fastcheck.load.seed_mobile_event`
- Run k6 scenarios from `performance/k6/mobile_scans.js`
- Use `MOBILE_SCAN_FORCE_ENQUEUE_FAILURE=true` only for the dedicated non-production enqueue-failure scenario
- Use `docker compose --profile perf-small up --build app-perf perf-proxy` for the opt-in capped app-tier path
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
