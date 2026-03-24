# Android Smoke Checklist

Use this checklist after environment or release-hardening changes.

Validate only the promoted Android contract:

- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

## Environment Check

- Build without source edits for the intended target.
- Confirm Diagnostics shows the expected `API Target`.
- Confirm Diagnostics shows the expected `Resolved Base URL`.
- Confirm release builds do not rely on emulator cleartext behavior.

## Field-Critical Flow

1. Login with a valid event and credential.
   Expected: authenticated session starts successfully.
   Failure means: target/base URL or auth contract drift.
2. Run attendee sync.
   Expected: attendee count and last sync state update successfully.
   Failure means: sync route, auth, or network policy drift.
3. Queue and upload one valid scan.
   Expected: local queue admits first, upload succeeds, confirmed server truth appears after flush.
   Failure means: queue/flush contract or network behavior drift.
4. Exercise one duplicate or replay-safe outcome.
   Expected: primary behavior still follows `status`; `reason_code` only refines operator wording.
   Failure means: truth-boundary drift in projection or persistence.
5. Verify queue depth and upload-state transitions.
   Expected: queue depth drops after terminal flush; upload state changes through uploading/retry/auth-expired/idle as appropriate.
   Failure means: coordinator or queue projection drift.
6. Verify 401 or auth-expired handling.
   Expected: queued scans remain queued; auth state becomes expired; nothing is silently discarded.
   Failure means: queue retention regression.
7. Verify sync rate-limit handling if available.
   Expected: rate-limited sync stays diagnostic and recoverable, without corrupting queue or auth state.
   Failure means: runtime hardening drift.

## Truth Boundary Checks

- Android still keys primary behavior off `status`.
- Missing `reason_code` is tolerated.
- `reason_code` refines operator truth only when present.
- Plain duplicate without `replay_duplicate` stays broader than final replay wording.
- No operator-visible truth is derived from `message`.
