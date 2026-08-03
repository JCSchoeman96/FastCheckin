# Runtime Data Retention Policy

Android keeps one Room database containing logical event buckets. Exactly one
bucket may be `ACTIVE`; inactive buckets are `PARKED` or `AUTH_REQUIRED` and
remain available for later re-authentication.

Normal login, logout, event switching, same-event re-authentication, auth
expiry, process death, and reboot do not delete attendees, sync metadata,
queued scans, admission overlays, replay suppression, quarantine evidence, or
event-scoped flush history.

Logout parks and snapshots the active bucket before clearing the matching
secure session generation. Expiry retains the bucket as `AUTH_REQUIRED`.
Logging into another event activates its bucket and parks the previous bucket;
unresolved inactive work is informational and never blocks authentication.

Only the currently authenticated event may sync or flush. Inactive events do
not use stored credentials or JWTs and resume only after manual login to that
event. Cleanup, retention, archive, and deletion policy are intentionally out
of scope.
