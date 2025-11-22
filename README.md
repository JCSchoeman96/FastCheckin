# FastCheck - PETAL Event Check-in System

**Replace Checkinera with a faster, self-hosted alternative**

FastCheck is a Phoenix-powered PETAL stack application that enables lightning-fast ticket validation, on-site attendee insights, and total control over the event check-in experience.

## 🚀 Motivation: Why Build FastCheck?
- **Problem:** Checkinera runs on hosted WordPress and often takes 500–1500 ms per scan while charging a recurring subscription fee.
- **Solution:** FastCheck delivers a self-hosted system that processes QR scans in just 10–50 ms, eliminating vendor lock-in and recurring costs.
- **Benefits:** Exceptional speed, customizable workflows, offline-capable after syncing, and complete ownership of the source code and infrastructure.

## ✨ Key Features
- ✓ 10–50 ms QR code scanning (≈40× faster than Checkinera)
- ✓ Offline-capable once attendee data is synced locally
- ✓ Support for multiple simultaneous events and venues
- ✓ Lifecycle-aware syncing using cached Tickera UTC start/end windows
- ✓ Real-time statistics, throughput charts, and live progress bars
- ✓ 100% source-code ownership with no vendor dependencies
- ✓ PostgreSQL database with tuned indexes for high-volume reads/writes
- ✓ Immutable audit trail for every check-in attempt
- ✓ Integration bridge for WordPress Tickera plugin data
- ✓ Multi-entrance support (Main, VIP, Staff, Vendors, etc.)
- ✓ Zero subscription fees—host it on your own VPS

## 🧱 Tech Stack
- **Backend:** Phoenix 1.7, Elixir/OTP, PubSub
- **Frontend:** LiveView, TailwindCSS, optional Svelte 5 widgets
- **Database:** PostgreSQL 12+ with replication-ready schema
- **Deployment:** systemd service on your VPS (Ubuntu/Debian), OpenLiteSpeed proxy, Let’s Encrypt SSL

## ⚡ Quick Start
```bash
# Prerequisites
elixir --version  # 1.17+
mix archive.install hex phx_new
psql --version    # 12+

# Create project skeleton
mix phx.new fastcheck --database postgres
cd fastcheck
mix ecto.create
```

## 🏗️ Architecture Overview
- **Data Flow:** Tickera API → FastCheck Tickera client → PostgreSQL → LiveView scanner interface.
- **Core Tables:** `events`, `attendees`, and `check_ins` with supporting indexes on ticket code, status, and entrance.
- **Real-time Updates:** LiveView WebSockets broadcast stats to every connected scanner in <50 ms.
- **Optimized Queries:** Query plans target single-digit millisecond response times even with 10k+ attendees.

## 📁 Project Structure
```
fastcheck/
├── lib/fastcheck/          # Application logic & contexts
├── lib/fastcheck_web/      # LiveView, controllers, components
├── priv/repo/              # Database migrations & seeds
├── config/                 # Runtime + environment config
├── test/                   # ExUnit + LiveView tests
└── assets/                 # Tailwind, JS, optional Svelte widgets
```

## 🛣️ Development Roadmap (13 Tasks)
1. **Days 1–2:** Phoenix foundation, Repo config, base schemas.
2. **Day 3:** Build Tickera API client (Req-based) + credential validation.
3. **Days 4–5:** Implement Events & Attendees contexts with syncing logic.
4. **Day 6:** Introduce check-in workflows, duplicate prevention, audit trail.
5. **Day 7:** Real-time PubSub instrumentation & stats aggregation.
6. **Day 8:** LiveView scanner + dashboard surfaces.
7. **Day 9:** Router wiring, auth gates, role-based entrances.
8. **Day 10:** Offline cache + sync reconciliation.
9. **Day 11:** Production config (systemd, env vars, SSL).
10. **Day 12:** Performance tuning, query optimization, indexes.
11. **Day 13:** QA, smoke tests, deployment automation.
12. **Bonus:** Multi-tenant event management & branding.
13. **Post-launch:** Observability, alerting, backup rotation.

## 🔍 Comparison
| Feature          | Checkinera        | FastCheck             |
|------------------|------------------|-----------------------|
| Scan Speed       | 500–1500 ms       | 10–50 ms              |
| Offline          | Limited cache     | Full after sync       |
| Cost             | Premium subscription | VPS hosting only   |
| Customization    | Restricted        | Complete control      |
| Data Ownership   | Tickera-hosted    | Your VPS / servers    |

## ☁️ Deployment Checklist
1. Provision Ubuntu/Debian VPS with PostgreSQL 12+.
2. Configure environment variables via `.env` and `systemd` unit (at minimum: `SECRET_KEY_BASE`, `ENCRYPTION_KEY`, `DATABASE_URL`, `MOBILE_JWT_SECRET`).
3. Build release (`MIX_ENV=prod mix release`) and run under systemd for auto-restart.
4. Terminate TLS using OpenLiteSpeed or Nginx with Let’s Encrypt certificates.
5. Enable database backups and monitoring dashboards (Prometheus/Grafana optional).

When you need Phoenix to terminate TLS directly (no reverse proxy), set `ENABLE_HTTPS=true` and optionally `HTTPS_PORT`, `SSL_CERT_PATH`, and `SSL_KEY_PATH` (defaults assume Let’s Encrypt). Leave `ENABLE_HTTPS=false` behind a proxy to skip binding the HTTPS listener entirely.

### Metrics exporter hardening
- The TelemetryMetricsPrometheus.Core reporter only starts in development or when `ENABLE_METRICS=true` is set.
- Metrics listen on `127.0.0.1` by default; expose them in production only behind authentication or a reverse proxy with IP whitelisting.

## 🧊 pgBouncer Connection Pooling
FastCheck now relies on pgBouncer to collapse hundreds of scanner connections into a
small number of PostgreSQL sessions. The new `docker-compose.yml` ships
three infrastructure services:

- `postgres` – canonical datastore for attendees and check-ins
- `pgbouncer` – transaction-level pooler listening on `6432`
- `redis` – caching layer introduced during extended tasks 6–11

Bring the infrastructure online with:

```
docker compose up -d postgres pgbouncer redis
```

Point the Phoenix release at `DATABASE_URL=ecto://postgres:password@pgbouncer:6432/fastcheck_prod`
so every Ecto connection flows through pgBouncer. The `/health` endpoint calls
`Ecto.Adapters.SQL.query/3` via pgBouncer to give load balancers a simple
readiness probe.

### Monitoring pgBouncer
Run the following commands from the host or via `docker exec fastcheck-pgbouncer`:

```
# Inspect pooled databases
psql -h localhost -p 6432 -U postgres -d pgbouncer -c "SHOW DATABASES"

# Active client sockets (FastCheck instances)
psql -h localhost -p 6432 -U postgres -d pgbouncer -c "SHOW CLIENTS"

# Pool utilization and wait times
psql -h localhost -p 6432 -U postgres -d pgbouncer -c "SHOW POOLS"

# Server connections to PostgreSQL
psql -h localhost -p 6432 -U postgres -d pgbouncer -c "SHOW SERVERS"

# Per-database throughput stats
psql -h localhost -p 6432 -U postgres -d pgbouncer -c "SHOW STATS"

# Effective configuration values
psql -h localhost -p 6432 -U postgres -d pgbouncer -c "SHOW CONFIG"
```

### Tuning cheatsheet
- `PGBOUNCER_DEFAULT_POOL_SIZE` – raise above 10 if scanners routinely wait for
  server slots (`avg_wait_time > 100ms` in `SHOW STATS`).
- `PGBOUNCER_RESERVE_POOL_SIZE` – bump when priority scans should always skip
  the queue.
- `PGBOUNCER_SERVER_LIFETIME` – lower for extremely busy systems to recycle
  long-lived transactions; raise when bulk imports hold transactions open.
- `PGBOUNCER_SERVER_IDLE_TIMEOUT` – trim to close idle upstream sessions
  aggressively if PostgreSQL resources are constrained.

Watch `SHOW POOLS` and `SHOW STATS` to validate the tweaks before deploying to
production.

### Troubleshooting connection issues
1. Run `curl -f http://localhost:4000/health` (or hit the load balancer health
   URL) to verify pgBouncer + PostgreSQL are reachable.
2. Check container health: `docker ps` should report both `postgres` and
   `fastcheck-pgbouncer` as `healthy`; inspect logs with
   `docker logs fastcheck-pgbouncer` if unhealthy.
3. Validate credentials with
   `psql -h localhost -p 6432 -U postgres -d fastcheck_prod -c "SELECT 1"`.
4. If pgBouncer is down, restart it via `docker compose up -d pgbouncer` or
   temporarily point `DATABASE_URL` back to `postgres:5432` until it recovers.
5. Persistent pooling errors usually stem from exhausting
   `PGBOUNCER_MAX_CLIENT_CONN`; scale the FastCheck app instances or raise the
   limit while keeping PostgreSQL’s `max_connections` under control.

## 📚 Implementation Guides
- [codex-project-plan.md](codex-project-plan.md) – All 13 task prompts.
- [codex-start-here.md](codex-start-here.md) – First three tasks to execute immediately.
- [AGENTS.md](AGENTS.md) – Project context & guardrails for AI contributors.
- [fastcheck-petal-guide.md](fastcheck-petal-guide.md) – Architecture & design patterns.

## 📈 Performance Targets
- **Scan latency:** <50 ms end-to-end, <20 ms DB writes.
- **Scalability:** 10,000+ attendees per event, 50+ concurrent scanners.
- **Events:** Unlimited simultaneous events with isolated stats.
- **Sync Cadence:** <2 minutes for 10k attendee pulls from Tickera.

## 🔐 Security Features
- API key validation and per-event credentials.
- SSL/TLS enforced for all endpoints.
- Immutable audit trail via the `check_ins` table and row-level locking.
- Database constraints prevent duplicate scans and orphaned attendees.
- Role-based LiveView guards to restrict entrances and admin actions.

### API authentication for check-ins
- `/api/v1/check-in` and `/api/v1/check-in/batch` now require a `Bearer` token issued by `/api/v1/mobile/login`.
- The authenticated token sets `current_event_id`; handlers ignore `event_id` parameters and reject missing/invalid tokens with `401`.
- Client example:
  ```bash
  TOKEN=$(curl -s -X POST https://fastcheck.example.com/api/v1/mobile/login -d '{"event_id":123,"credential":"secret"}' | jq -r '.data.token')
  curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"ticket_code":"ABC-123"}' https://fastcheck.example.com/api/v1/check-in
  ```

### Mobile API rate limiting
- `/api/v1/mobile/attendees` and `/api/v1/mobile/scans` run through the shared rate limiter in `FastCheckWeb.Plugs.RateLimiter`.
- Attendee syncs use the strict sync tier (default `RATE_LIMIT_SYNC=3` requests per event per five minutes); scan uploads use the
  scan tier (default `RATE_LIMIT_SCAN=50` requests per IP per minute).

## 📋 Status & Next Steps
- **Status:** Pre-development (scaffold + planning only).
- **Next Step:** Run **TASK 0B – Project Scaffold** to create the folder hierarchy and placeholder modules.
- **Then:** Follow **TASK 1** in `codex-start-here.md` to configure `mix.exs` and base dependencies.

## 🤝 Contributing & License
- Contributions welcome from the South African events community and beyond.
- Released under the MIT License — fork, extend, and deploy your own FastCheck instance!

Built with ❤️ for high-velocity event teams who need speed, reliability, and full control.
