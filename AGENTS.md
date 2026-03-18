This repository is FastCheck, a Phoenix and LiveView event check-in system with a separate Kotlin Android scanner app.

Use this file as the project-specific source of truth before making changes.

- When verifying android/scanner-app from WSL/Linux, do not assume the Windows Android SDK path in local.properties is usable; prefer Windows-side gradle (gradlew.bat) or a native Linux Android SDK, and rely on Gradle toolchain resolution for JDK 25.

## Beads / bd Task Tracking

- Use `bd` for new features, blockers, dependencies, technical debt, deferred work, docs follow-ups, infra follow-ups, and cross-file refactors.
- Do not use broad TODO comments for work that spans files, phases, or PRs.
- A local `TODO` / `FIXME` is only acceptable when it is:
  - file-local,
  - small,
  - concrete,
  - and likely to be resolved in the same PR or immediate next PR.
- When discovering new blockers or follow-up work, create a Beads item immediately instead of leaving vague comments.

Examples:
- `bd create "Fix attendee count diagnostics regression" -p 1 -t bug`
- `bd create "Add reason_code to mobile scan outcome contract" -p 2 -t feature`
- `bd create "Wrap attendee sync writes in one Room transaction" -p 2 -t task`

Dependency examples:
- `bd dep add <child-id> <parent-id>`

Agent workflow:
Before substantial work:
- bd dolt status
- bd dolt start
- Check `bd ready` before starting substantial work.
- Use `bd update <id> --claim` when taking ownership.
- Use `bd close  <id> --reason "Done"` when the work is actually finished.

## Project Rules

- Create and claim a worktree for each implementation or group of implementations
- When finished closed down and create a PR with detailed descriptions
- Run `mix precommit` after repo changes and fix anything it reports.
- Use `Req` for HTTP work in Elixir. Do not introduce `HTTPoison`, `Tesla`, or `:httpc`.
- Keep LiveView templates wrapped in `<Layouts.app ...>`.
- Use HEEx, `to_form/2`, `<.form>`, `<.input>`, and `<.icon>` consistently.
- Do not add inline `<script>` tags in HEEx. Browser JS belongs in `assets/js/app.js` and related assets.
- Prefer existing local components in `lib/fastcheck_web/components/` before adding new UI primitives.
- Follow `.formatter.exs` for Elixir formatting and `assets/package.json` for frontend formatting support.
- Android does not currently use `ktlint`, `detekt`, or `spotless`; follow the existing Kotlin style and `android/scanner-app/docs/architecture.md`.

## Project Snapshot

- Phoenix app: `Phoenix 1.8.1`, `Phoenix LiveView 1.1.17`, Elixir `~> 1.17`.
- Backend source of truth: Tickera data synced into PostgreSQL, then served locally for browser and scanner flows.
- Browser runtime: LiveView admin and operations UI for event setup, sync, dashboarding, occupancy, and scanner portal.
- Active scanner runtime: Kotlin Android app in `android/scanner-app`, built as a local-first queue-and-flush scanner client.

Current high-level split:

- LiveView/browser owns event management, sync orchestration, operator-facing browser tools, and exports.
- Android owns camera capture, local attendee cache, queued offline scans, and background flush.
- Phoenix remains the business-rule authority for authentication, attendee sync, and scan acceptance.

## Architecture Split

### LiveView and browser-owned surfaces

- Dashboard and event management: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/live/dashboard_live.ex`
- Browser scanner surface: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/live/scanner_live.ex`
- Mobile-first scanner portal: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/live/scanner_portal_live.ex`
- Occupancy view: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/live/occupancy_live.ex`

### Active mobile API for Android today

- Mobile login: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/controllers/mobile/auth_controller.ex`
- Mobile attendee sync and scan upload: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/controllers/mobile/sync_controller.ex`

These routes are the active Android runtime contract:

- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

### Future native-scanner scaffold only

- Native scanner check-in scaffold: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/controllers/api/v1/check_in_controller.ex`
- Event package scaffold: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/controllers/api/v1/package_controller.ex`
- Event config scaffold: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/controllers/api/v1/event_config_controller.ex`

Do not couple the Android runtime to these routes yet:

- `POST /api/v1/device_sessions`
- `POST /api/v1/check_ins`
- `POST /api/v1/check_ins/flush`
- `GET /api/v1/events/:event_id/config`
- `GET /api/v1/events/:event_id/package`
- `GET /api/v1/events/:event_id/health`

These are present as future-facing scaffold, not the promoted Android contract.

### Android scanner source of truth

- Android architecture note: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/docs/architecture.md`

The Android architecture doc explicitly states that runtime work must stay on `/api/v1/mobile/*` until the backend formally promotes a new contract.

## Phoenix Runtime Map

### Router and auth boundaries

- Router: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/router.ex`

Primary router split:

- `:browser` and `:dashboard_auth` for dashboard and admin LiveViews
- `:scanner_auth` for browser scanner portal sessions
- `:api` for public JSON and future scaffold endpoints
- `:api_authenticated` for JWT-protected legacy JSON check-in routes
- `:mobile_api` for JWT-protected Android mobile routes
- `:device_api` plus `:require_event_assignment` for the future device-session scaffold

### Active browser routes

- `live "/"` and `live "/dashboard"` -> dashboard
- `live "/scan/:event_id"` -> browser scanner
- `live "/dashboard/occupancy/:event_id"` -> occupancy
- `live "/scanner/:event_id"` -> scanner portal behind scanner session auth
- CSV exports:
  - `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/controllers/export_controller.ex`

### Active mobile auth

- JWT issuance: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck/mobile/token.ex`
- Mobile JWT verification plug: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/plugs/mobile_auth.ex`

Mobile auth rules:

- Android authenticates with `event_id` plus `credential`.
- Phoenix issues an event-scoped JWT.
- `current_event_id` comes from verified token claims, not request body or query params.

### Future device-session auth scaffold

- Device auth plug: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/plugs/api_auth.ex`

This is for the future revocable device-session model. It is not the active Android contract.

### Domain anchors for events, attendees, and scan decisions

- Event schema and scanner policy fields: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck/events/event.ex`
- Attendee schema and local scan-state fields: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck/attendees/attendee.ex`
- Attendee context facade: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck/attendees.ex`
- Native scanner scaffold service: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck/check_ins/check_in_service.ex`
- Offline package schema: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck/check_ins/offline_event_package.ex`

Important attendee fields already persisted on the Phoenix side include:

- `ticket_code`
- `normalized_code`
- `first_name`
- `last_name`
- `email`
- `ticket_type`
- `allowed_checkins`
- `checkins_remaining`
- `payment_status`
- `checked_in_at`
- `checked_out_at`
- `last_checked_in_at`
- `is_currently_inside`
- `last_entrance`

### UI and styling conventions

- App helper and imports: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web.ex`
- Core components: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/components/core_components.ex`
- Layout wrapper: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/components/layouts.ex`
- Tailwind entrypoint: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/assets/css/app.css`

This repo already uses:

- Tailwind v4 import syntax in `assets/css/app.css`
- the local FastCheck component set under `lib/fastcheck_web/components/`
- Mishka Chelekom vendor CSS in `assets/vendor/mishka_chelekom.css`

Prefer extending the existing design system over introducing parallel component patterns.

## Android Scanner Runtime Map

### Build and platform baseline

Key files:

- Gradle settings: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/settings.gradle.kts`
- App build: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/build.gradle.kts`
- Manifest: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/AndroidManifest.xml`

Current Android baseline:

- Android Gradle Plugin `9.1.0`
- Kotlin Gradle plugin `2.3.10`
- `compileSdk = 36`
- `targetSdk = 36`
- host JDK `25`
- Java and Kotlin bytecode target `17`
- Hilt, Room, Retrofit, OkHttp, WorkManager, CameraX, and ML Kit are already in use

### Android runtime layers

Source-of-truth files:

- Retrofit boundary: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/network/PhoenixMobileApi.kt`
- Session header and auth plumbing live under `core/network` and session repositories
- Remote DTOs: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/remote/RemoteModels.kt`
- Local attendee cache entity: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/AttendeeEntity.kt`
- Sync repository: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepository.kt`
- Scan queue and flush repository: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepository.kt`
- Session auth gateway: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentSessionAuthGateway.kt`
- Background flush worker: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/worker/FlushQueueWorker.kt`
- Scanner decode pipeline: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/usecase/ScanCapturePipeline.kt`

### Android runtime rules

- CameraX and ML Kit decode into local queueing only.
- Scanner analysis code must not call network code directly.
- Local queueing happens before network upload.
- WorkManager owns retryable background flush.
- The backend remains the authority for check-in acceptance and business rules.
- Android must not depend on gates, devices, offline packages, or future `/api/v1` device endpoints until formally promoted.

### Android attendee model

Android currently stores a trimmed attendee cache, not the full Phoenix schema.

Local entity fields in `AttendeeEntity`:

- `id`
- `eventId`
- `ticketCode`
- `firstName`
- `lastName`
- `email`
- `ticketType`
- `allowedCheckins`
- `checkinsRemaining`
- `paymentStatus`
- `isCurrentlyInside`
- `updatedAt`

Important contract note from `CurrentPhoenixSyncRepository`:

- Preserve backend `ticket_code` exactly as delivered until QR normalization is explicitly defined and promoted.

## Active API Contracts And Data Shapes

### Response envelope conventions

Primary versioned API convention:

- success: `%{data: ..., error: nil}`
- handled controller error: `%{data: nil, error: %{code: ..., message: ...}}`

Standardized fallback controller:

- `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/controllers/fallback_controller.ex`

Important exception:

- `FastCheckWeb.Plugs.MobileAuth` returns `401` responses as `%{error: "...", message: "..."}`
- do not change this casually without a deliberate contract change

### `POST /api/v1/mobile/login`

Phoenix controller:

- `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/controllers/mobile/auth_controller.ex`

Android DTO:

- `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/remote/RemoteModels.kt`

Request body:

```json
{
  "event_id": 123,
  "credential": "secret-code"
}
```

Success shape:

```json
{
  "data": {
    "token": "jwt",
    "event_id": 123,
    "event_name": "Event Name",
    "expires_in": 86400
  },
  "error": null
}
```

### `GET /api/v1/mobile/attendees`

Phoenix controller:

- `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/controllers/mobile/sync_controller.ex`

Android API boundary:

- `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/network/PhoenixMobileApi.kt`

Query params:

- optional `since`
- `since` is parsed as ISO8601
- invalid `since` currently falls back to a full sync

Success shape:

```json
{
  "data": {
    "server_time": "2026-03-13T10:00:00Z",
    "attendees": [],
    "count": 0,
    "sync_type": "full"
  },
  "error": null
}
```

Serialized attendee fields are exactly:

- `id`
- `event_id`
- `ticket_code`
- `first_name`
- `last_name`
- `email`
- `ticket_type`
- `allowed_checkins`
- `checkins_remaining`
- `payment_status`
- `is_currently_inside`
- `checked_in_at`
- `checked_out_at`
- `updated_at`

Formatting expectations:

- timestamps are ISO8601 strings or `null`
- `allowed_checkins` defaults to `1` if missing
- `checkins_remaining` falls back to `allowed_checkins` and then `1`
- `is_currently_inside` falls back to `false`

### `POST /api/v1/mobile/scans`

Phoenix controller:

- `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/controllers/mobile/sync_controller.ex`

Android queue and upload implementation:

- `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepository.kt`

Request body:

```json
{
  "scans": [
    {
      "idempotency_key": "uuid-or-stable-key",
      "ticket_code": "25955-1",
      "direction": "in",
      "scanned_at": "2026-03-13T10:00:00Z",
      "entrance_name": "Main",
      "operator_name": "Scanner 1"
    }
  ]
}
```

Current scan upload rules:

- `direction` must be `"in"` or `"out"`
- `"out"` is currently not implemented on the Phoenix side and returns an error result
- idempotency is enforced server-side
- upload results are per scan, not just per batch

Success shape:

```json
{
  "data": {
    "results": [
      {
        "idempotency_key": "uuid-or-stable-key",
        "status": "success",
        "message": "Check-in successful"
      }
    ],
    "processed": 1
  },
  "error": null
}
```

Android-specific contract rules:

- do not invent new payload fields without changing both Phoenix and Android DTOs
- do not normalize or rewrite `ticket_code` differently from Phoenix until the contract is formally updated
- keep queue-and-flush behavior local-first

## Working Rules For Future Changes

### When changing Phoenix

- Start at the router and the relevant controller or LiveView before changing behavior.
- If a change touches Android sync or scan upload, confirm the active route is still under `/api/v1/mobile/*`.
- Keep LiveView pages wrapped in `<Layouts.app ...>`.
- Prefer existing components from `lib/fastcheck_web/components/` and `core_components.ex`.
- Keep JSON response shapes stable unless you are intentionally versioning the contract.
- Use the fallback controller pattern for controller-level JSON errors where appropriate.

### When changing attendee or event data

- Check both the persisted schema and the serialized contract.
- Do not assume Android consumes every Phoenix field.
- If you add or rename attendee fields in the mobile sync payload, update:
  - Phoenix serialization in `Mobile.SyncController`
  - Android DTOs in `RemoteModels.kt`
  - Room entities and mappers if the new field is stored locally

### When changing Android scanner flow

- Keep the path as: CameraX or ML Kit decode -> local queue -> WorkManager flush.
- Do not let camera or analyzer code make direct network calls.
- Preserve replay suppression, idempotency, and queued-scan behavior.
- Keep auth scoped to the event JWT session model until the backend promotes the device-session API.

### When changing formatting or frontend assets

- Elixir formatting is controlled by `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/.formatter.exs`
- Frontend formatting support lives in `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/assets/package.json`
- Tailwind entrypoint is `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/assets/css/app.css`
- Preserve the Tailwind v4 import pattern already in `app.css`

### Quick source-of-truth index

- Router: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/router.ex`
- Mobile login: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/controllers/mobile/auth_controller.ex`
- Mobile sync and uploads: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/controllers/mobile/sync_controller.ex`
- Fallback error format: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/controllers/fallback_controller.ex`
- Event schema: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck/events/event.ex`
- Attendee schema: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck/attendees/attendee.ex`
- Browser scanner surfaces: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/live/scanner_live.ex` and `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/lib/fastcheck_web/live/scanner_portal_live.ex`
- Android architecture: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/docs/architecture.md`
- Android API boundary: `/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/network/PhoenixMobileApi.kt`
