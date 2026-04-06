# Android Scanner Architecture

## Active Runtime Contract

The Android scanner app depends only on these Phoenix endpoints at runtime:

- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

Future backend routes and entities are quarantined from Android runtime. The
app must not depend on `/api/v1/device_sessions`, `/api/v1/check_ins`,
`/api/v1/check_ins/flush`, config/package/health routes, gates, devices, or
offline packages until the backend formally promotes a new contract.

## Authoritative Runtime Truth

Android is local-first, but the backend is authoritative for scan admission.

- Android queues scans locally before upload.
- Auto-flush is the normal upload path; manual flush remains fallback/debug.
- Backend admission happens synchronously in hot state during
  `POST /api/v1/mobile/scans`.
- Durability is queued before acknowledgement.
- Durable Postgres projection happens asynchronously afterward.

Repo/runtime mode truth must stay explicit:

- repo config still falls back to `:legacy` unless runtime overrides it
- authoritative tests and local perf paths are pinned to
  `:redis_authoritative`
- Android does not target `:legacy` or `:shadow`; those remain backend
  migration/fallback modes

## Layer Map

- `core.network`: Retrofit/OkHttp and current Phoenix mobile API boundary
- `core.database`: Room database
- `core.datastore`: non-secret session metadata
- `core.security`: secure JWT storage
- `data.remote`: DTOs matching current Phoenix JSON payloads
- `data.local`: Room entities and DAO
- `data.mapper`: layer-to-layer mapping only
- `data.repository`: runtime repositories behind app-facing interfaces
- `domain.model`: runtime models
- `domain.usecase`: local-first queue and flush orchestration
- `feature.queue`: temporary manual/debug queue UI only
- `feature.scanning.camera`: CameraX preview and binding setup only
- `feature.scanning.analysis`: ML Kit decode boundary only
- `feature.scanning.domain`: scanner-local models and defaults
- `feature.scanning.usecase`: decoded-value handoff into queueing only
- `feature.scanning.ui`: scanner permission/status UI state only
- `feature.*`: UI/ViewModel state boundaries
- `worker`: WorkManager queue flush

## Runtime Boundaries

- CameraX/ML Kit decode into local queueing only.
- The temporary manual/debug queue UI lives in `feature.queue` only.
- `feature.scanning` owns real scanner preview, analyzer, permission, and
  decode handoff work.
- Scanner analysis must never call network code directly.
- Room is the structured local source for attendee cache, queued scans, replay
  cache, and sync metadata.
- The Phoenix backend remains the business-rule authority.
- Foreground/manual flush orchestration is owned by `core.autoflush`.
- WorkManager remains the mechanism for retryable background flush when/if
  enqueued.
- JWT auth is isolated behind `SessionRepository`, `SessionAuthGateway`,
  `SessionProvider`, `SessionVault`, and session metadata storage.
- The backend request path remains:
  `validate -> hot-state decision -> enqueue durability -> promote results -> respond`
- No per-scan durable Postgres mutation belongs in the request path before
  acknowledgement.

## Truth Model

- **Durable truth** lives in repositories/Room and is exposed as observable
  `Flow`s such as queue depth and persisted flush outcomes.
- **Transient orchestration truth** lives in `AutoFlushCoordinator.state`
  (uploading, retry scheduled metadata, auth expired signal).
- **UI/ViewModels** are projection-only and must not pretend that local queue
  capture equals server-confirmed admission.

## Hilt Scope

Hilt is used for:

- Retrofit/OkHttp wiring
- Room database and DAO injection
- secure token vault and DataStore-backed stores
- repository bindings
- queue/flush use cases
- scanner decode handler and ML Kit scanner engine
- WorkManager worker injection

Custom WorkManager initialization exists only because Hilt worker injection
requires a non-default worker factory. No other custom WorkManager behavior is
allowed unless a concrete repo-level need is documented.

## Build Baseline

The Android toolchain baseline for this project is:

- Android Gradle Plugin `9.1.0`
- Gradle wrapper `9.3.1`
- `compileSdk = 36`
- `targetSdk = 36`
- Android SDK Build Tools `36.0.0`
- Host JDK `25`
- Java/Kotlin bytecode target `17`

AGP built-in Kotlin is enabled. KSP replaces kapt for Room and Hilt code
generation. The repo must not commit machine-specific `org.gradle.java.home`
or `sdk.dir` paths. Keep `android/scanner-app/local.properties` machine-local,
set `JAVA_HOME` per host, and verify the actual runtime with `./gradlew
--version` or `.\gradlew.bat --version`, because `JAVA_HOME` alone can be
misleading when the shell resolves a different Java binary via `PATH`.

## References

- [CameraX Analyze](https://developer.android.com/media/camera/camerax/analyze)
- [ML Kit Barcode Scanning](https://developers.google.com/ml-kit/vision/barcode-scanning/android)
- [App Architecture](https://developer.android.com/topic/architecture)
- [Data Layer](https://developer.android.com/topic/architecture/data-layer)
- [Hilt on Android](https://developer.android.com/training/dependency-injection/hilt-android)
