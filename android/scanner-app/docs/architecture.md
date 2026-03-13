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
- `feature.scanning.analysis`: ML Kit decode boundary, detection mapping, and frame admission control
- `feature.scanning.domain`: scanner-local state machine, cooldown, result, overlay, and capture models
- `feature.scanning.usecase`: scanner loop orchestration and decoded-value handoff into queueing
- `feature.scanning.ui`: scanner permission/status UI state and runtime activation boundary
- `feature.*`: UI/ViewModel state boundaries
- `worker`: WorkManager queue flush

## Runtime Boundaries

- CameraX/ML Kit decode into local queueing only.
- The temporary manual/debug queue UI lives in `feature.queue` only.
- `feature.scanning` owns real scanner preview, analyzer, permission, and
  decode handoff work. It is the clean home for real scanner capture flow
  before CameraX code grows further.
- Scanner analysis must never call network code directly.
- Room is the structured local source for attendee cache, queued scans, replay
  cache, and sync metadata.
- The Phoenix backend remains the business-rule authority.
- WorkManager owns retryable background flush.
- JWT auth is isolated behind `SessionRepository`, `SessionAuthGateway`,
  `SessionProvider`, `SessionVault`, and session metadata storage.

## Hilt Scope

Hilt is used for:

- Retrofit/OkHttp wiring
- Room database and DAO injection
- secure token vault and DataStore-backed stores
- repository bindings
- queue/flush use cases
- scanner capture/feedback/camera/format config
- scanner decode handler, real analyzer binding, frame gate, and ML Kit scanner engine
- WorkManager worker injection

Scanner replay suppression remains queue/repository-owned. Scanner feedback
cooldown is a separate scanner config concern. The shared app `Clock` remains
the only time abstraction; scanner modules must not provide a second clock.

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
generation. Host verification must use `./gradlew --version` or
`.\gradlew.bat --version`, because `JAVA_HOME` alone can be misleading when the
shell resolves a different Java binary via `PATH`.

## References

- [CameraX Analyze](https://developer.android.com/media/camera/camerax/analyze)
- [ML Kit Barcode Scanning](https://developers.google.com/ml-kit/vision/barcode-scanning/android)
- [App Architecture](https://developer.android.com/topic/architecture)
- [Data Layer](https://developer.android.com/topic/architecture/data-layer)
- [Hilt on Android](https://developer.android.com/training/dependency-injection/hilt-android)
