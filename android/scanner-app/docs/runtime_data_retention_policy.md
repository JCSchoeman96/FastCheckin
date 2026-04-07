# Runtime Data Retention Policy

## Purpose

This policy defines how Android scanner runtime data is retained or cleared
across session transitions. It reflects the current production baseline where:

- unresolved local gate-state blocking already exists
- queued scans are durable operational truth
- local admission overlays are durable unresolved-state truth
- quarantined scans are durable audit/runtime truth

Retention logic must live at repository/session boundaries, not in UI code.

## Runtime Data Surfaces

- `queued_scans`
- `local_admission_overlays`
- `quarantined_scans`
- `attendees`
- `sync_metadata`
- `local_replay_suppression`
- `scan_replay_cache`
- `latest_flush_snapshot`
- `recent_flush_outcomes`
- session credential (`SessionVault`) and session metadata (`SessionMetadataStore`)

## Transition Contract

### Explicit logout

- clear session credential + metadata
- preserve `queued_scans`
- preserve `local_admission_overlays`
- preserve `quarantined_scans`
- clear `attendees`
- clear `sync_metadata`
- clear `local_replay_suppression`
- clear `scan_replay_cache`
- clear `latest_flush_snapshot`
- clear `recent_flush_outcomes`

### Auth expiry

- clear session credential + metadata
- preserve `queued_scans`
- preserve `local_admission_overlays`
- preserve `quarantined_scans`
- preserve `attendees`
- preserve `sync_metadata`
- clear `local_replay_suppression`
- preserve `scan_replay_cache`, `latest_flush_snapshot`, and `recent_flush_outcomes`
  by default for same-event recovery context

### Same-event re-login

- allow
- preserve queue, overlays, quarantine, attendee cache, and sync metadata

### Clean event transition (no unresolved local gate state for old event)

- allow
- preserve durable state that remains valid (`queued_scans`, `local_admission_overlays`,
  `quarantined_scans`)
- clear prior event attendee cache + sync metadata
- clear replay suppression/cache and flush surfaces for prior event context

### Different-event login with unresolved local gate state

- block login
- preserve `queued_scans`, `local_admission_overlays`, `quarantined_scans`
- do not auto-discard and do not reuse new event token for old unresolved state

### Restored-session blocked by unresolved local gate state

- clear only session credential + metadata
- must not run explicit-logout runtime cleaner path unless policy explicitly says so
- keep route blocked with an operator-facing message

### Crash/restart/process death

- preserve Room runtime data
- do not run cleanup solely because process restarted

## Guardrail Terms

- Use **unresolved local gate state** (not queue-only wording).
- Current unresolved gate state includes unreplayed queue + active overlays.
- Quarantined scans are retained by default and should only be removed via
  explicit, approved policy.
