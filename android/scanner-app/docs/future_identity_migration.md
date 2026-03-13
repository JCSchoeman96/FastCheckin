# Future Identity Migration

## Current Seam

`SessionAuthGateway` is the narrow runtime seam that hides today’s event-scoped
JWT login model from scanner capture and UI flows.

## What Can Change Later

Future backend identity may introduce:

- durable device registration
- device sessions
- gate assignment
- stronger session revocation rules

## What Must Not Change

These Android areas should remain untouched when identity changes:

- scanner capture pipeline
- Room queue model
- WorkManager flush flow
- feature-level UI state contracts

## Migration Rule

Replace implementations behind:

- `SessionRepository`
- `SessionAuthGateway`
- `SessionProvider`
- secure token/session stores

Do not push hybrid identity details into scanner features before the backend
runtime contract actually changes.
