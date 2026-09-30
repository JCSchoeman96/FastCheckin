# P1-D Event-Scoped Sales Dashboard Authorization

## Goal

Prevent a dashboard identity from reading or changing Sales records for an
Event that the server has not granted to that identity. The URL, form, loaded
Order, TicketIssue, or Event must never create the grant being checked.

P1-D is a P0 launch blocker. It introduces no organization model, membership
table, general RBAC redesign, or migration.

## Authority Model

The current dashboard authenticates one configured username/password identity.
Authentication proves identity only. `DASHBOARD_ALLOWED_EVENT_IDS` supplies the
server-owned Sales Event allowlist.

Configuration rules:

- Missing or blank value means no Sales Event access.
- A valid value is a comma-separated list of positive integer Event IDs.
- Whitespace is trimmed and duplicate IDs are sorted and deduplicated.
- Any nonblank malformed value raises a runtime configuration error. The list
  is never partially accepted.
- No wildcard, all-Events fallback, Event enumeration, browser/session grant,
  or grant derived from a requested record is allowed.

`FastCheck.Sales.DashboardAccess.actor_for_identity/1` is the canonical
dashboard identity-to-Sales actor constructor. Service boundaries resolve
grants from the identity and may narrow a query to an Event only after proving
that Event is in the configured grant set.

## P1-D-REV-01 authority decision

The current production Sales dashboard revocation entry point is admin-only. DashboardAccess resolves the configured dashboard identity and server-owned Event grants. FastCheck.Tickets.Revocation retains domain-level :operator support for callers that already established trusted identity and Event scope; the core does not authenticate callers. No production operator entry point exists. Track trusted operator identity and Event authority as FastCheckin-iuaq.

## Covered Surfaces

- Sales dashboard lists, summaries, filters, and order detail.
- Manual-review queue, entity context, audit notes, assignments, retries, and
  review transitions.
- Refund, revocation, and admin ticket PDF.
- Operations metrics and recent failure rows.
- Audit timeline entity and transition lookup.
- Admin-assisted and internal-pilot checkout.
- Event overview, WhatsApp offer list and mutations, inventory initialization
  retry, and Event WhatsApp quantity-cap changes.
- Root-dashboard WhatsApp Sales enable/disable and create-time enable option.

List and aggregate reads constrain ownership in SQL/Ash. User filters only
narrow grants. Guessed ungranted entity IDs return the same safe not-found
behavior as unavailable records. Mutations revalidate the server grant before
the existing state transition, advisory lock, inventory, or worker behavior.

Audit ownership resolves through durable records: child Sales records through
their Order, DeliveryAttempt through its direct `sales_order_id`, Conversation
through `sales_orders.whatsapp_conversation_id` and the Conversation `wa_id`,
PaymentEvent through its provider/reference PaymentAttempt, AttendeeInvalidation
through its direct Event, and StateTransition through its referenced entity.
Missing or ambiguous owners are denied.

## Verification Requirements

Use distinct Event A and Event B fixtures. Exercise the real dashboard identity
resolution and prove:

- A-only grants permit Event A and deny Event B list, detail, audit, checkout,
  offer, PDF, and mutation paths.
- A+B grants permit both Events.
- Empty grants expose no Sales Event-owned data and deny mutations.
- Rejected mutations leave durable rows, success audit records, Oban jobs, and
  Redis inventory unchanged where applicable.
- Malformed runtime configuration is rejected in full.
- Existing refund/revocation, inventory, lock, and worker atomicity remains
  intact.

No permission DB table, Redis permission authority, per-row grant lookup, or
per-Event query loop is added. Existing Event and Order ownership indexes are
used; no migration is expected.

## Explicitly Separate Work

P1-D is limited to Sales authorization. It does not claim application-wide
BrowserAuth Event isolation. Root-dashboard general Event administration and
sync, `/export/attendees/:event_id`, `/export/check-ins/:event_id`,
`/scan/:event_id`, and `/dashboard/occupancy/:event_id` remain in a separately
tracked security slice.

No scanner/mobile redesign, payment/refund state change, inventory change,
ticket authority change, or customer-session change is included.

## P1-D-REV-02 global worker monitoring boundary

Event-scoped `OpsMetrics` excludes global and unattributable Oban backlog data.
This is an intentional security boundary because Oban jobs do not have a safe
Event owner. P1-D does not provide global operational monitoring, and its
Sales Ops dashboard must not be used as a global backlog source.

Global Oban backlog monitoring remains an open P0 launch-readiness blocker.
Production launch is NO-GO until an approved global monitoring source and
rehearsed procedure exist. P1-F owns that follow-up. P1-D does not establish
launch readiness.
