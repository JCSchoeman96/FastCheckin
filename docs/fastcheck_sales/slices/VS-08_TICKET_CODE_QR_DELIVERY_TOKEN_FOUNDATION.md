# VS-08 Ticket Code, QR, and Delivery Token Foundation

## Purpose

VS-08 adds pure Elixir security primitives for Sales ticket identifiers. This slice
does not issue tickets, create attendees, or change scanner behavior.

## Modules

- `FastCheck.Tickets.CodeGenerator` — DB-free `FC-` ticket code candidates (128-bit entropy)
- `FastCheck.Tickets.TokenHash` — purpose-bound HMAC-SHA256 hashing (`:delivery`, `:qr`)
- `FastCheck.Tickets.QrPayload` — scanner QR payload builder/parser
- `FastCheck.Tickets.DeliveryToken` — secure ticket-page bearer token primitives

## Identifier model

| Identifier | Stored plaintext? | Stored hash? | Purpose |
|---|---:|---:|---|
| `ticket_code` | Yes (on TicketIssue) | No | Support/admin + scanner bridge |
| `qr_token` | No | `qr_token_hash` | Optional opaque QR secret |
| `delivery_token` | No | `delivery_token_hash` | Secure customer ticket page |

## QR payload format (release)

**Scanner compatibility decision:** current Phoenix and Android scanner paths decode the
barcode to a plain `ticket_code` string and look up `event_id + ticket_code` on
`Attendee`. They do not parse `FC1:` prefixes.

Therefore:

- `QrPayload.build_for_scanner/1` returns the plain `ticket_code`.
- `FC1:<value>` parsing is supported for forward compatibility only and is **not**
  used for the release scanner path.

## Token hashing

- Config key: `:ticket_token_pepper` (`TICKET_TOKEN_PEPPER` in production)
- Algorithm: HMAC-SHA256 with purpose-prefixed input:
  - `"delivery:" <> plaintext`
  - `"qr:" <> plaintext`
- Delivery and QR hashes are cryptographically separated even if plaintext is reused.

## Delivery token expiry

- Default TTL: `:sales_delivery_token_ttl_seconds` (90 days)
- `DeliveryToken.verify_context/2` returns `:invalid`, `:expired`, or `:revoked`

## Database indexes added

- `sales_ticket_issues_qr_token_hash_uidx`
- `sales_ticket_issues_delivery_token_hash_uidx`
- `sales_ticket_issues_delivery_token_expires_at_idx`
- `sales_ticket_issues_status_delivery_token_expires_at_idx`

## Deferred integration

- VS-09A/B/C/D — issuance, TicketIssue creation, attendee bridge
- VS-11 — secure ticket page hash lookup
- VS-15A — revocation and token rotation persistence

## Out of scope (unchanged)

No `Tickets.Issuer`, no order-driven TicketIssue creation, no Attendee mutation, no
scanner/mobile changes, no payment/checkout/inventory/WhatsApp/email delivery behavior.
