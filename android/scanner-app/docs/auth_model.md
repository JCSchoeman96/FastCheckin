# Auth Model

## Current Runtime Model

Authentication is event-scoped and uses:

- `POST /api/v1/mobile/login`
- request body `{ "event_id": ..., "credential": ... }`
- response payload containing JWT, `event_id`, `event_name`, and `expires_in`

## Storage Split

- JWT, event ID, generation, authentication time, expiry, and the last-issued
  generation counter: encrypted storage via `AuthenticatedEventContextStore`
- non-secret metadata: DataStore via `SessionMetadataStore`

The encrypted context is authoritative. DataStore is a repairable display
cache and never authorizes a request or determines restored-session validity.

## Session Boundary

- `SessionRepository`: login/logout/current session
- `SessionAuthGateway`: read current event/operator runtime identity
- `AuthenticatedSessionTransitionCoordinator`: compensated Room/secure-store/
  DataStore transitions
- `AuthenticatedEventContextStore`: atomic event/token/generation snapshots

UI and scanner features must not depend on JWT parsing or storage mechanics.

## Auth Expiry

- sync and flush compare the captured generation before applying auth expiry
- queued scans remain in Room
- local admission overlays remain in Room
- quarantined scans remain in Room
- no credential is persisted for silent re-login
- operator must re-authenticate manually

Logout parks the active bucket before clearing the matching secure generation.
Auth expiry marks that generation's bucket `AUTH_REQUIRED`. Neither transition
deletes event-local runtime data.

## Future Scope

Hybrid device/session auth may replace event-scoped JWT login later. That
migration must happen behind the existing session boundary instead of touching
scanner UI, queueing, or worker flows.
