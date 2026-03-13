# Diagnostics

Current diagnostics should focus on runtime realities of the current Phoenix
mobile contract.

## Core Signals

- current event/session metadata
- JWT auth-present vs auth-expired state
- attendee sync recency
- pending queue depth
- replay cache behavior
- last successful flush outcome
- connectivity state
- thermal state placeholder
- app version

## Scope Limit

Diagnostics must not assume future backend device-session or package-health
surfaces yet. If those routes exist on the server, they are future-facing only
for Android runtime.
