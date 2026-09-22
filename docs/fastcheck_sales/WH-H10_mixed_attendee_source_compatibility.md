# WH-H10: Mixed attendee source compatibility (#432)

**Status:** compatibility proof + regression tests (no scanner identity redesign).

## Attendee ownership

| Origin | `Attendee.source` | Durable owner |
| --- | --- | --- |
| WordPress / Tickera sync | `tickera` | Tickera sync and authoritative reconciliation |
| FastCheck ticket issuance (WhatsApp / Sales) | `fastcheck_sales` | FastCheck Sales / ticket issuer |

Both origins write scanner-visible rows into the shared `attendees` table. That table is the durable check-in state operators and devices rely on.

`source`, `source_reference`, `sales_order_id`, and `sales_ticket_issue_id` are **provenance and audit metadata**. They are not scanner lookup keys.

## Canonical scanner identity

For check-in and check-out, attendee identity within an Event is:

```text
event_id + ticket_code
```

`source` does **not** form a second scanner namespace. Tickera and FastCheck Sales attendees on the same Event use the same `FastCheck.Attendees.Scan` entrypoints and the same `scan_eligibility` / payment / remaining check-in rules.

## Collision model

- FastCheck Sales ticket codes are issued via the existing high-entropy `FC-` generator with collision-safe retry at issuance time.
- There is only one scanner row per `(event_id, ticket_code)`.
- If a `fastcheck_sales` row already owns that pair, Tickera bulk upsert must **not** overwrite or reclassify it. See `test/fastcheck/attendees/origin_protection_test.exs`.
- WH-H10 does not change this model or add `(event_id, source, ticket_code)` lookup.

## Authority boundaries

```text
Tickera
  → owns Tickera-source attendee synchronization and reconciliation

FastCheck Sales / ticket issuer
  → owns fastcheck_sales attendee creation and Sales linkage fields

Attendee (DB row)
  → scanner-visible ticket state

TicketIssue
  → issuance audit / token linkage (Sales)

Scan
  → check-in / check-out authority for both origins
```

Payment and `TicketIssue` metadata must not become scanner lookup authority.

## Browser scanner

Implementation: `FastCheckWeb.ScannerSessionController`.

- Login uses **Event database ID** plus **event credential** (mobile access secret), not `scanner_login_code`.
- A successful session stores `scanner_event_id` and locks scans to that Event.
- Attendee resolution during scanning uses `event_id + ticket_code` within the locked Event.

`scanner_login_code` appears in operator UI copy (for example when describing which Event is locked) but is **not** the browser scanner login lookup key.

## Android / mobile scanner

Implementation: `FastCheckWeb.Mobile.AuthController`, `FastCheckWeb.Mobile.SyncController`.

- `POST /api/v1/mobile/login` accepts **event_id** and **credential**; JWT claims scope the device to that Event ID.
- `GET /api/v1/mobile/attendees` returns **active** attendees for the authenticated Event (`scan_eligibility == "active"`), regardless of Tickera vs Sales origin.
- Mobile JSON omits internal lineage: `source`, `source_reference`, `sales_order_id`, `sales_ticket_issue_id`, and revocation internals where already hidden.

Do not expose `source` to mobile clients to satisfy mixed-origin compatibility; Event-scoped active attendee sync is sufficient.

## `scanner_login_code` (Event field)

- Six-character Crockford-style code generated on Event insert when absent (`FastCheck.Events.Event`).
- Unique index `idx_events_scanner_login_code`.
- Used for operator-facing labels and **future** device-session lookup (`Events.get_event_by_scanner_login_code/1` in the device API scaffold).
- **Not** the active browser or Android login identifier today (those use numeric `event_id`).

Do not conflate:

- Event database `id`
- `scanner_login_code`
- Tickera remote event identifiers
- Attendee `ticket_code`
- Sales `source_reference` (`sales:{order_id}:{line_id}:{sequence}`)

## Regression coverage (WH-H10)

| Proof | Location |
| --- | --- |
| Same Event, both sources, shared scan path | `test/fastcheck/attendees/mixed_source_compatibility_test.exs` |
| Tickera must not overwrite Sales on code collision | `test/fastcheck/attendees/origin_protection_test.exs` |
| Reconciliation invalidates Tickera-only absences | `test/fastcheck/attendees/origin_protection_test.exs` |
| Mobile sync includes Sales without lineage leak | `test/fastcheck_web/controllers/mobile/sync_controller_test.exs` |
| Sales scans through existing path | `test/fastcheck/attendees/scan_test.exs` |

## Non-goals (this slice)

No changes to checkout, Paystack, issuance state machine, ReservationLedger, H01–H09 delivery/sales UX, scanner acceptance rules, or Android app code.
