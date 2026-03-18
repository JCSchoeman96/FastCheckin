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
- **Data**: PostgreSQL (Docker compose uses Postgres 15). Optional pgBouncer + Redis are provided in `docker-compose.yml`.
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
- `direction = "out"` is currently not implemented for successful mobile flows (see the contract doc).

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

- Postgres direct: `ecto://postgres:${DB_PASSWORD}@localhost:5432/fastcheck_prod`
- pgBouncer: `ecto://postgres:${DB_PASSWORD}@localhost:6432/fastcheck_prod`

### Run the app

```bash
mix setup
mix phx.server
```

Health endpoint:

- `GET /api/v1/health`

### Environment variables

See `.env.example` for the full set of production-style env vars. At minimum you’ll need values for `SECRET_KEY_BASE`, `ENCRYPTION_KEY`, `MOBILE_JWT_SECRET`, and `DATABASE_URL` in the environment you run the server under.

## Local development (Android scanner)

Start here:

- `android/scanner-app/docs/architecture.md`
- `android/scanner-app/CURRENT_PHOENIX_MOBILE_API.md`

Build/run via Android Studio or Gradle in `android/scanner-app/`.

## Deployment notes (infra + pooling)

- `docker-compose.yml` provides **Postgres 15**, **pgBouncer** (transaction pool mode), and **Redis**.
- pgBouncer is intended to collapse many client connections into a smaller number of upstream Postgres sessions; monitor it with `SHOW POOLS` / `SHOW STATS` via psql.
- `.env.example` includes knobs such as `POOL_SIZE`, `ENABLE_HTTPS`, and TLS cert paths.

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
- `CONTRIBUTING.md` (formatting workflow)
