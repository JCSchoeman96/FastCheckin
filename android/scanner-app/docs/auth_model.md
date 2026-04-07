# Auth Model

## Current Runtime Model

Authentication is event-scoped and uses:

- `POST /api/v1/mobile/login`
- request body `{ "event_id": ..., "credential": ... }`
- response payload containing JWT, `event_id`, `event_name`, and `expires_in`

## Storage Split

- JWT: secure storage only via `SessionVault`
- non-secret metadata: DataStore via `SessionMetadataStore`

This split prevents the UI and sync layers from coupling to token storage
details.

## Session Boundary

- `SessionRepository`: login/logout/current session
- `SessionAuthGateway`: read current event/operator runtime identity
- `SessionProvider`: bearer-token provider for the network layer

UI and scanner features must not depend on JWT parsing or storage mechanics.

## Auth Expiry

- background flush treats HTTP `401` as auth-expired
- queued scans remain in Room
- local admission overlays remain in Room
- quarantined scans remain in Room
- no credential is persisted for silent re-login
- operator must re-authenticate manually

Auth expiry and explicit logout are different transitions:

- explicit logout clears credential + metadata and applies explicit logout
  retention cleanup
- auth expiry clears credential + metadata but preserves same-event recovery
  surfaces (attendee/sync context) per runtime retention policy

Restored-session blocking for unresolved local gate state is separate from
explicit logout semantics: it clears credential + metadata and must not run the
explicit-logout cleaner path unless policy explicitly requires it.

## Future Scope

Hybrid device/session auth may replace event-scoped JWT login later. That
migration must happen behind the existing session boundary instead of touching
scanner UI, queueing, or worker flows.
