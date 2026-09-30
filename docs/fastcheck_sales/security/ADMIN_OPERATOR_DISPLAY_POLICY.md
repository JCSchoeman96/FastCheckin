# Admin Operator Display Policy

## List View Defaults

List views should show operational status without unnecessary PII:

- Show `public_reference`, status/state, amount, currency, source channel, event,
  timestamps, and masked provider reference.
- Mask phone numbers by default.
- Mask email addresses by default.
- Do not show `access_code`.
- Do not show raw provider payloads.
- Do not show `delivery_token_hash` or `qr_token_hash`.
- Do not show full provider response errors by default if they may contain PII.

Masking examples:

- `+2782******34`
- `j***@example.com`
- `payref...1234`

## Detail View Defaults

- Admin may reveal more event-scoped detail when required for support.
- Operator detail access is narrower than admin detail access.
- Raw payload reveal is explicit and restricted.
- Manual reveal actions should be auditable where practical.

## Forbidden Defaults

- Operator sees all events by default.
- Sales admin views list or aggregate records without the authenticated Event
  grant filter.
- Payment/order/ticket lookup is unscoped.
- Public references resolve records without event/channel-safe checks.

## Current Dashboard Boundary

P1-D enforces server-configured Event grants across dedicated Sales dashboard
surfaces and the root dashboard's Sales-specific controls. The root dashboard's
general Event management and sync tools, CSV exports, browser scanner, and
occupancy views still use the broader BrowserAuth boundary. They remain a
separate event-isolation security follow-up; P1-D does not claim those routes
are Event-isolated.
