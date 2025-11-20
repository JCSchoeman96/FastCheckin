---
trigger: always_on
---

The mobile client is offline-first: all attendee data and queued scans are stored locally (Dexie or equivalent).

Attendees in local storage must be keyed by (event_id, ticket_code) to prevent cross-event leakage.

Sync down uses server-provided server_time as the only reference for future since queries; do not trust local clocks.

Sync up sends queued scans and processes server responses to clean or mark queue entries. Do not drop scans silently.

Do not add logic that assumes constant connectivity (no “scan → always hit server first” patterns).