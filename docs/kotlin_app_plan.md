1. Purpose

Build a native Kotlin Android scanner app for FastCheck that integrates with the current Phoenix mobile API and current FastCheck event/attendee sync model.

This app is not being built against the future native-scanner schema yet. It must ship against the existing runtime contracts first, while keeping clean seams for a later move to device/session identity, gates, config versioning, and offline packages.

2. Source of truth
Runtime source of truth now

The Kotlin app must treat these as the active runtime contract:

POST /api/v1/mobile/login

GET /api/v1/mobile/attendees

POST /api/v1/mobile/scans

The backend remains the source of truth for:

JWT authentication

event scope

Tickera sync and normalization

payment-status enforcement

duplicate prevention

remaining-checkins enforcement

row locking

audit logging

Not runtime source of truth yet

Do not build the Kotlin app against the planned-but-not-wired native-scanner structures yet:

devices

device_sessions

gates

offline_event_packages

scanner_policy_mode

config_version

These may exist in migrations, but until they are wired into schemas, controllers, serializers, and runtime behavior, they are groundwork only.

3. Strategic decisions
Locked decisions

Build against current FastCheck Phoenix mobile API

Use current event-scoped JWT auth

Use event_id + credential for login

Use Room for attendee cache and queued scans

Use WorkManager for retryable flush

Use CameraX + ML Kit for the native scanner

Treat direction = "in" as the only supported runtime flow for now

Do not mirror the current TS mobile app if it diverges from Phoenix controllers

Design clean abstraction seams for future hybrid device/session identity

Explicit non-goals for v1

no direct PostgreSQL access

no gate-scoped runtime requirements

no checkout flow in production mobile path

no offline package dependency

no strong local approval engine that pretends to match server business rules perfectly

4. Why this architecture is correct

CameraX is the Android-recommended starting point for new camera apps, ML Kit supports on-device barcode scanning with CameraX integration, Hilt provides the standard Dagger-based DI path on Android, Room is the standard structured local database abstraction, DataStore is the Jetpack async transactional key-value / typed-object store, and WorkManager is the recommended system for persistent retryable background work. Phoenix also explicitly supports JSON APIs, LiveView remains a good fit for rich real-time operator dashboards, and Phoenix.Token is a standard token mechanism for API authentication flows.

5. Current FastCheck reality

Based on your current FastCheck setup:

Backend already does

validates and stores event setup server-side

stores Tickera connection info and scanner/mobile secrets in Postgres

syncs attendees from Tickera into local Postgres

exposes mobile login, attendee sync, and scan upload endpoints

issues event-scoped JWTs

derives event scope from the JWT, not request params

enforces exact ticket_code lookup

uses row locking with FOR UPDATE NOWAIT

rejects non-completed payments

rejects duplicates when remaining check-ins are exhausted

decrements checkins_remaining

writes audit rows

Current mobile contract limitations

mobile attendee serializer does not expose all internal attendee fields

direction: "out" is not functionally implemented for the mobile sync endpoint

the old TS mobile app is not a safe contract source because it drifts from the Phoenix batch shape

future scanner runtime tables are scaffolded in DB only, not yet active contract

6. Backward planning
Ultimate goal

A native scanner app that:

logs into a FastCheck event securely

syncs attendee data locally

scans tickets continuously on Android hardware

works through intermittent connectivity

queues scans safely offline

flushes scans reliably

keeps operators fast and clear at the gate

can evolve later into device/session/gate-aware architecture without rewrite

Final production system

Long-term, the system should support:

hybrid identity (device + session)

gate assignment

config versioning

richer offline policy modes

package-based offline support

more explicit diagnostics and reconciliation workflows

MVP slice

The MVP is smaller:

current mobile login contract

attendee sync into Room

CameraX + ML Kit scanner

local replay suppression

queue scans locally

flush scans via current /api/v1/mobile/scans

basic diagnostics

clear online/offline/expired-token states

That is the right MVP because it is aligned to the backend you already have, instead of waiting for future backend architecture to be finished.

7. Domain model
7.1 Backend domains the app depends on

Events

Attendees

Mobile Auth

Mobile Sync

Check-ins

7.2 Android app domains

Auth

Session

Attendee Sync

Scanning

Queue

Diagnostics

Settings

7.3 Core entities
Remote/API entities

MobileLoginRequest

MobileLoginResponse

MobileAttendeeDto

ScanUploadRequest

ScanUploadItemDto

ScanUploadResultDto once response contract is stabilized

Local persistence entities

AttendeeEntity

QueuedScanEntity

ReplayCacheEntity

SyncStateEntity

Domain/UI models

SessionState

ScannerResult

AttendeeSummary

PendingScan

FlushOutcome

7.4 State machines
Session state

LoggedOut -> LoggingIn -> Active -> Expired | Revoked | Invalid

Sync state

Idle -> Syncing -> Synced | PartialFailure | Failed

Scanner state

Ready -> Processing -> AcceptedOnline | QueuedOffline | Rejected | Cooldown

Queue state

Pending -> Uploading -> Synced | Conflict | FailedTerminal

8. Architecture boundaries
8.1 Phoenix responsibilities

Phoenix owns:

event validation

Tickera secret handling

attendee normalization

authoritative attendee state

payment and duplicate rules

row locks and database concurrency

audit history

JWT issuance and validation

8.2 Kotlin app responsibilities

Android owns:

native camera scanning

secure token/session persistence

attendee cache

incremental sync

queue persistence

local replay suppression

background flush retries

operator feedback

diagnostics

8.3 Clean seam requirement

The Kotlin app must be structured so future auth changes only affect auth/data layers, not scanner UI or queue logic.

That means:

UI never owns raw JWT logic

CameraX analyzer never calls network directly

Retrofit DTOs never become the UI or Room models directly

9. Recommended Android project structure

Use this structure:

kotlin_app/
  app/
    build.gradle.kts
    src/main/AndroidManifest.xml
    src/main/java/com/fastcheckin/scanner/
      app/
        FastCheckinApplication.kt

      core/
        network/
        database/
        datastore/
        security/
        common/
        time/

      data/
        remote/
          api/
          dto/
        local/
          entity/
          dao/
        repository/
        mapper/
        session/

      feature/
        auth/
        sync/
        scanning/
        queue/
        diagnostics/
        settings/

      worker/
      navigation/
10. Naming conventions
Package root

com.fastcheckin.scanner

File and type rules

Retrofit interfaces end with Api

Room entities end with Entity

DAOs end with Dao

repositories end with Repository

mappers end with Mapper

workers end with Worker

state holders end with State

DTOs end with Dto

Forbidden patterns

no Utils

no Helpers

no giant Manager dumping grounds

no single data class reused for Retrofit + Room + UI

11. Auth model
Runtime now

Current login contract:

POST /api/v1/mobile/login
{ "event_id": 123, "credential": "scanner-secret" }

Response includes:

token

event_id

event_name

expires_in

The app must store:

JWT securely

expiry metadata

event metadata separately

last successful login timestamp

Architecture seam for future hybrid identity

Even though runtime now is event JWT only, the app must isolate auth behind:

AuthRepository

SessionStore

SessionProvider

This way, future support for:

device_id

session_id

gate_id

can be added without rewriting scanner, queue, or sync layers.

12. Network model

Use Retrofit interfaces for Phoenix mobile APIs because Retrofit turns HTTP APIs into typed interfaces, while OkHttp provides efficient HTTP behavior including connection pooling, HTTP/2 support, transparent compression, and resilience around common network problems.

API surface to target

MobileAuthApi

MobileSyncApi

Runtime requests

login

attendee sync with optional since

scan flush with { "scans": [...] }

Hard rules

never send { "batches": ... }

never derive event scope from request params after login

always use bearer JWT on protected mobile routes

13. Local persistence model

Room is the correct local storage for structured attendee and queue data because it provides an abstraction over SQLite suited to offline cache and structured local records. DataStore is the right fit for lightweight app state, and Kotlin coroutines are the right async model because they are lightweight and designed for non-blocking structured concurrency.

13.1 Room tables
attendees

Fields:

id

event_id

ticket_code

first_name

last_name

email

ticket_type

allowed_checkins

checkins_remaining

payment_status

is_currently_inside

checked_in_at

checked_out_at

updated_at

Indexes:

unique (event_id, ticket_code)

index (event_id, updated_at)

index (event_id, payment_status)

queued_scans

Fields:

local_id

event_id

idempotency_key

ticket_code

direction

scanned_at

entrance_name

operator_name

status

attempt_count

last_attempted_at

server_result_code

server_result_message

created_at

Indexes:

unique idempotency_key

index (status, created_at)

index (event_id, status)

replay_cache

Fields:

ticket_code

last_seen_at

last_result

Purpose:

suppress local burst duplicate scans

short TTL in app logic only

sync_state

Fields:

event_id

last_attendee_sync_at

last_full_sync_at

last_successful_flush

13.2 DataStore keys

event_id

event_name

jwt_expires_at

last_login_at

selected_entrance_name

operator_name

audio_enabled

vibration_enabled

13.3 Secure storage

Use Android Keystore-backed protection for secret material because Keystore is specifically designed to keep cryptographic keys difficult to extract and non-exportable.

14. Scanner engine

CameraX is the right scanner base because Android recommends it for new camera apps. ML Kit’s barcode guidance also explicitly recommends ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST for CameraX and warns against using native camera resolution for barcode scanning because it hurts latency without improving accuracy; it also notes that streaming results can vary frame to frame and consecutive confirmation may be needed for confidence.

14.1 Stack

CameraX preview + image analysis

ML Kit barcode scanning

duplicate suppression window

cooldown after result

queue handoff

no synchronous network call from analyzer

14.2 Locked scanner rules

do not analyze every frame

drop frames when analyzer is busy

do not use native camera resolution

keep barcode formats restricted to what Tickera actually emits

analyzer must hand off locally first

queue/network flush is asynchronous

local replay suppression must exist

14.3 UX states

ready

processing

accepted_online

queued_offline

rejected_duplicate

rejected_invalid

rejected_payment

token_expired

sync_backlog_warning

15. Sync strategy
15.1 Initial sync

After login:

store session

fetch attendees

upsert attendees into Room

set latest updated_at watermark

15.2 Incremental sync

Use:
GET /api/v1/mobile/attendees?since=<ISO8601>

Rules:

upsert by (event_id, ticket_code)

overwrite server-owned fields

treat backend as authoritative merged attendee state

15.3 Flush strategy

WorkManager is correct here because it is intended for reliable work that must continue even if the app exits or the device restarts, and it is the recommended replacement for older Android scheduling APIs.

Flush flow:

read pending scans

send a small batch to /api/v1/mobile/scans

classify result per scan

mark queue rows

update local attendee cache if backend response supports it

schedule next batch if backlog remains

16. Offline model
v1 offline policy

Do not pretend the device can fully replicate server business rules.

For v1:

offline scan capture is allowed

scans are queued locally

UI marks them clearly as pending upload

final authoritative decision arrives from backend flush

This is the safest model because your current mobile attendee payload does not expose all internal fields needed for a robust local approval engine.

v2 offline policy

Only after backend adds richer config/contracts should the app support stronger local approval heuristics.

17. Performance and scaling review
Current FastCheck reality

Your current runtime already depends on:

Postgres attendee cache

exact ticket lookups

DB row locking

JWT event scope

audit writes

That means the Kotlin app should not introduce fake local authority. It should be a fast native capture client with resilient sync.

Android performance rules

CameraX + ML Kit only

keep latest frame only

low enough resolution for latency

no heavy work on main thread

coroutines for IO

no DB/network in analyzer hot loop

Backend performance rules

small scan payloads

idempotency key per scan

batch flush size must be bounded

keep scan response minimal

add explicit result codes if not already stable

18. Security review
Do now

HTTPS only

bearer JWT on mobile APIs

Keystore-backed secret handling

token expiry validation

session clear on auth failure

Do not do by default

Do not make certificate pinning a blanket requirement. Android’s current security guidance explicitly warns that certificate pinning is not recommended for most Android apps because future server certificate changes can break clients until a software update is shipped.

19. Backend gaps to close

These are the backend gaps the Kotlin app should plan around.

Gap 1 — stable scan result contract

The app needs per-scan structured result mapping from /api/v1/mobile/scans.

Needed fields per returned scan:

idempotency_key

status

reason_code

message

ticket_code

checkins_remaining

checked_in_at

is_currently_inside

Gap 2 — normalization ambiguity

You need a hard answer on whether scanned QR content is always exactly ticket_code.

If not, backend must expose one of:

normalization support in mobile scan upload

resolver behavior server-side

normalized code in serializer

Gap 3 — event config endpoint

The app needs a lightweight config endpoint eventually.

Minimum useful config:

event_name

check-out enabled flag

offline allowed flag

barcode formats

cooldown settings

config version later

Gap 4 — direction=out

Current mobile execution path does not actually support it.
So:

model it in types

disable it in runtime UI

do not build checkout UX now

Gap 5 — canonical contract doc

The TS mobile app already drifted. FastCheck needs one canonical mobile API contract doc.

20. Recommended implementation order
Phase 1

Contract lock:

freeze current mobile API shapes

freeze current auth assumptions

document known limitations

Phase 2

Android scaffold:

Hilt

Retrofit

OkHttp

Room

DataStore

Keystore-backed secret storage

navigation shell

diagnostics shell

Phase 3

Scanner:

CameraX

ML Kit

replay suppression

result state machine

queue handoff

Phase 4

Sync:

full sync

incremental sync

queue flush

retry/backoff

token expiry recovery

Phase 5

Backend hardening:

structured scan results

normalization answer

event config

batch policy

auth expiry semantics

Phase 6

Future runtime evolution:

device/session identity

gates

config versioning

offline packages

richer policy modes

21. Success criteria

The scaffold and first implementation slices are correct only if:

current FastCheck mobile API is the only runtime contract

auth is abstracted behind a session boundary

DTOs, Room entities, and domain/UI models are separate

queue is idempotency-first

analyzer never blocks on network

replay suppression exists

direction="in" is the only enabled runtime direction

future hybrid identity is planned but not wired into runtime yet