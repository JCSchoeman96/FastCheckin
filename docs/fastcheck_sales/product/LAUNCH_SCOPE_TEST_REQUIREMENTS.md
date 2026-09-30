# Launch Scope Test Requirements

## Future Tests Required By Selected Scope

- Orders created from WhatsApp have `source_channel = whatsapp`.
- Orders created from admin-assisted flow have `source_channel = admin`.
- Orders created from internal pilot have `source_channel = test` or accepted
  pilot attribution.
- Future web checkout orders have `source_channel = web` only when that path is
  implemented later.
- All selected source channels use `ReservationLedger`.
- All selected source channels create `PaymentAttempt` through the approved
  Paystack path.
- All selected source channels require Paystack server-side verification before
  ticket issuance.
- All selected source channels issue tickets only through the approved issuer.
- All selected source channels record `StateTransition` audit.
- All ticket delivery/resend flows record `DeliveryAttempt`.
- Revocation is scanner-visible for tickets from every selected source channel.
- PII/log redaction applies to every selected source channel.
- Admin/operator list/read/manual-action tests deny cross-event records.

## Dashboard Event-Grant Tests

P1-D must prove the configured dashboard identity is limited to its server
grant set across Sales list and aggregate reads, entity detail, manual review,
refund/revocation, admin PDF, checkout, offers, Event overview, operations, and
audit timelines.

- With Event A only granted, Event A succeeds and guessed or filtered Event B
  reads fail closed.
- With Events A and B explicitly granted, both are usable.
- With no grants, Sales Event-owned lists are empty and mutations are denied.
- Malformed nonblank `DASHBOARD_ALLOWED_EVENT_IDS` configuration is rejected;
  malformed IDs are never partially accepted.
- Rejected Event B mutations leave durable rows, audit actions, Oban jobs, and
  Redis inventory unchanged where those effects apply.
- Root-dashboard Sales controls are hidden for ungranted Events and reject
  direct LiveView events naming them.

P1-D does not cover general root-dashboard Event administration/sync, CSV
exports, browser scanner, or occupancy. Their Event-isolation tests belong to a
separate BrowserAuth security slice.

## VS-22 Impact

VS-22 must cover:

- WhatsApp-first paid core.
- Internal pilot bridge.
- Admin-assisted secondary path.
- Deferred web checkout remains out of first launch scope.
