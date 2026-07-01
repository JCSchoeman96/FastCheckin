# VS-24B — PDF Ticket Generation Feature Pack

## 1. Backward Planning

### Ultimate Goal

FastCheck needs one ticket-validity source and multiple renderers:

```text
Issued ticket -> ArtifactResolver -> Web ticket / PDF / Apple Wallet / Google Wallet
```

VS-24B adds the PDF renderer only. It must not create a second ticket resolver, new delivery path, or alternate scanner/payment authority.

### Work Backwards

Final production artifact system requires:

1. `ArtifactResolver` remains the authority for “is this ticket currently renderable?”
2. Renderers consume `%FastCheck.Tickets.Artifact{}` only.
3. PDF generation returns safe PDF bytes through a safe `Document` struct.
4. PDF generation never mutates tickets, attendees, orders, payments, deliveries, revocations, or scanner state.
5. Delivery of PDFs is a later slice, not VS-24B.

### MVP

The smallest viable VS-24B is:

- extend `Artifact` with safe optional event metadata needed by PDFs;
- create a PDF generation boundary;
- create a PDF document/error contract with safe `Inspect`;
- create deterministic template and QR scan representation;
- wrap HTML-to-PDF rendering behind a behaviour;
- test valid generation, invalid states, redaction, no mutation, and secure-page regression.

No route. No storage. No migration. No delivery.

---

## 2. Domain Model / Resource Map

### Existing Resources

| Resource | Current Role | VS-24B Rule |
|---|---|---|
| `FastCheck.Tickets.ArtifactResolver` | Resolves delivery token to safe artifact/error | Only validity source for PDF |
| `FastCheck.Tickets.Artifact` | Valid renderer-neutral ticket projection | Extend with safe optional event metadata |
| `FastCheck.Tickets.ArtifactError` | Non-renderable state | Return as-is for invalid PDF requests |
| `FastCheck.Sales.TicketPage` | Legacy secure-page adapter | Preserve exact six-field map |
| `FastCheckWeb.SecureTicketController` | Secure ticket route | Do not change |
| `FastCheck.Events.Event` | Event date/time/location metadata | Source via ArtifactResolver only |
| `FastCheck.Tickets.Issuer` | Ticket issuance | Do not call |
| `FastCheck.Tickets.Revocation` | Revocation and scanner visibility | Do not call |
| `FastCheck.Attendees.Scan` | Scanner mutation | Do not call |
| `SendWhatsAppTicketLinkWorker` | Link delivery | Do not call |

### New Modules

| Module | Responsibility |
|---|---|
| `FastCheck.Tickets.PdfTicket` | Public generation boundary |
| `FastCheck.Tickets.PdfTicket.Document` | PDF bytes result; custom `Inspect` redacts bytes |
| `FastCheck.Tickets.PdfTicket.Error` | Safe renderer error |
| `FastCheck.Tickets.PdfTicket.Template` | Deterministic escaped HTML |
| `FastCheck.Tickets.PdfTicket.QrCode` | QR/SVG/data URI from artifact scanner payload |
| `FastCheck.Tickets.PdfTicket.Renderer` | Behaviour/port |
| `FastCheck.Tickets.PdfTicket.ChromicRenderer` | Production renderer adapter |
| `FastCheck.Tickets.PdfTicket.FakeRenderer` | Test renderer under `test/support` |

### Invariants

- PDFs are generated only from valid artifacts.
- Invalid `ArtifactError` states do not produce PDFs.
- `TicketPage.resolve/1` remains unchanged externally.
- PDF bytes may contain the scanner payload, but logs/inspect/errors/filenames must not.
- No PDF is persisted in VS-24B.

---

## 3. Current Repo Findings

- Issue #439 says VS-24B must generate server-side PDFs from the shared ticket artifact contract and excludes delivery, Apple Wallet, Google Wallet, checkout, Paystack, issuance, scanner validation, revocation, webhooks, and delivery authority changes.
- PR #413 is merged; VS-24A baseline exists on `main`.
- `Artifact` currently contains `state`, `event_name`, `attendee_name`, `ticket_type`, `scanner_payload`, `scanner_payload_format`, `support_message`, `issued_at`, and `delivery_expires_at`, with custom `Inspect` redacting scanner payload.
- `ArtifactResolver` currently validates delivery token, loads `TicketIssue`, verifies `DeliveryToken`, loads `Attendee` and `Event`, checks archived event, scan eligibility and payment status, then builds `scanner_payload` through `QrPayload.build_for_scanner/1`.
- `TicketPage.resolve/1` currently preserves the secure-page legacy shape and maps artifact `scanner_payload` back to `qr_payload`.
- `Event` already has `event_date`, `event_time`, `location`, and `entrance_name` fields.
- `mix.exs` currently has no PDF generation dependency.

---

## 4. Architecture Proposal

### 4.1 Extend Artifact With Safe Metadata

Add optional fields to `FastCheck.Tickets.Artifact`:

```text
event_date
event_time
event_location
entrance_name
```

Populate them in `ArtifactResolver` from the already loaded `Event`.

Rules:

- These are display-only customer artifact fields.
- Do not expose them through `TicketPage.resolve/1`.
- Do not print them through `inspect(artifact)`.
- Do not add IDs, URLs, phone, email, payment fields, provider fields, token hashes, or raw structs.

### 4.2 PDF Public API

Create `FastCheck.Tickets.PdfTicket` with:

```text
generate_from_delivery_token(raw_token, opts \ [])
generate_from_artifact(%FastCheck.Tickets.Artifact{} = artifact, opts \ [])
```

Returns:

```text
{:ok, %FastCheck.Tickets.PdfTicket.Document{}}
{:error, %FastCheck.Tickets.ArtifactError{}}
{:error, %FastCheck.Tickets.PdfTicket.Error{}}
```

Rules:

- Delivery-token path calls `ArtifactResolver.resolve_from_delivery_token/1`.
- Invalid artifacts return `ArtifactError` and do not call renderer.
- Artifact path does not touch DB.
- No writes, no token rotation, no scanner/revocation/payment/issuer/delivery calls.

### 4.3 Document Contract

Create `PdfTicket.Document` fields:

```text
bytes
content_type
filename
byte_size
sha256
generated_at
```

Rules:

- `content_type` is `application/pdf`.
- `filename` is generic and safe, for example `fastcheck-ticket.pdf`.
- `bytes` may contain scanner payload because the PDF needs scan material.
- `inspect(document)` must not print bytes, scanner payload, names, location, tokens, hashes, URLs, phone, email, raw HTML, provider or payment values.

### 4.4 Error Contract

Create `PdfTicket.Error` states:

```text
:renderer_unavailable
:render_failed
:invalid_artifact
```

Rules:

- Do not store raw HTML or raw renderer exceptions if they may contain HTML.
- Custom `Inspect` exposes only coarse state/reason.

### 4.5 QR / Scan Representation

Create `PdfTicket.QrCode`.

Rules:

- Input is `artifact.scanner_payload` only.
- Do not call `QrPayload.build_for_scanner/1` again in the PDF layer.
- Do not create new QR tokens or use QR token hashes.
- Output deterministic SVG/data URI.
- Recommended dependency: `eqrcode`.

### 4.6 Template

Create `PdfTicket.Template`.

Include:

- event name;
- date/time/location/entrance when present;
- attendee display name when present;
- ticket type;
- QR scan image;
- human-readable scanner code;
- support message;
- issued/delivery expiry if useful.

Rules:

- Escape all scalar display values.
- Inline CSS only.
- No external URLs, scripts, fonts, images, remote CSS, or tracking.
- Do not log generated HTML.

### 4.7 Renderer Boundary

Create `PdfTicket.Renderer` behaviour and `PdfTicket.ChromicRenderer` adapter.

Recommended dependency: `chromic_pdf` for production HTML-to-PDF.

Rules:

- Unit tests use fake renderer; normal precommit should not require Chrome/Ghostscript.
- Production adapter returns safe `PdfTicket.Error` if unavailable/fails.
- Do not call `ChromicPDF` outside the adapter.
- Configure bounded concurrency/timeouts.

---

## 5. Files To Create / Update

### Create

```text
lib/fastcheck/tickets/pdf_ticket.ex
lib/fastcheck/tickets/pdf_ticket/document.ex
lib/fastcheck/tickets/pdf_ticket/error.ex
lib/fastcheck/tickets/pdf_ticket/template.ex
lib/fastcheck/tickets/pdf_ticket/qr_code.ex
lib/fastcheck/tickets/pdf_ticket/renderer.ex
lib/fastcheck/tickets/pdf_ticket/chromic_renderer.ex
test/support/fastcheck/tickets/pdf_ticket/fake_renderer.ex
test/fastcheck/tickets/pdf_ticket_test.exs
test/fastcheck/tickets/pdf_ticket/template_test.exs
docs/fastcheck_sales/feature_packs/0046_VS-24B_pdf-ticket-generation/README.md
docs/fastcheck_sales/feature_packs/0046_VS-24B_pdf-ticket-generation/VS-24B-FEATURE_PACK.md
docs/fastcheck_sales/feature_packs/0046_VS-24B_pdf-ticket-generation/TOON_PROMPTS.md
docs/fastcheck_sales/feature_packs/0046_VS-24B_pdf-ticket-generation/CODING_AGENT_PROMPT.md
docs/fastcheck_sales/feature_packs/0046_VS-24B_pdf-ticket-generation/pack.json
docs/fastcheck_sales/feature_packs/0046_VS-24B_pdf-ticket-generation/POST_MERGE_HANDOFF_TEMPLATE.md
```

### Update

```text
mix.exs
mix.lock
config/config.exs
config/test.exs
lib/fastcheck/application.ex
lib/fastcheck/tickets/artifact.ex
lib/fastcheck/tickets/artifact_resolver.ex
test/fastcheck/tickets/artifact_resolver_test.exs
test/fastcheck/sales/ticket_page_test.exs
```

### Do Not Change

```text
lib/fastcheck_web/controllers/secure_ticket_controller.ex
lib/fastcheck_web/controllers/secure_ticket_html/show.html.heex
lib/fastcheck_web/router.ex
lib/fastcheck/workers/send_whatsapp_ticket_link_worker.ex
lib/fastcheck/sales/delivery_attempt.ex
lib/fastcheck/tickets/issuer.ex
lib/fastcheck/tickets/revocation.ex
lib/fastcheck/tickets/scanner_visibility.ex
lib/fastcheck/attendees/scan.ex
```

### Do Not Create

```text
docs/fastcheck_sales/handoffs/VS-24B_IMPLEMENTATION_HANDOFF.md
```

---

## 6. In Scope / Out Of Scope

### In Scope

- PDF generation boundary.
- Artifact metadata extension.
- PDF document/error structs with custom `Inspect`.
- QR scan representation from artifact scanner payload.
- Template and renderer behaviour.
- Fake test renderer.
- Tests and feature-pack docs.

### Out Of Scope

- Public route/download controller.
- WhatsApp/email delivery.
- PDF persistence/storage.
- Apple/Google Wallet.
- Wallet signing.
- Migrations.
- Redis/Cachex/CDN/browser storage.
- Payment/checkout/Paystack/webhook changes.
- Issuer/scanner/revocation changes.
- DeliveryAttempt changes.
- Token rotation.

---

## 7. Risks And Edge Cases

| Risk | Required Handling |
|---|---|
| Revoked/expired ticket PDF | Return `ArtifactError`; renderer not called |
| Renderer unavailable | Return safe `PdfTicket.Error{state: :renderer_unavailable}` |
| Renderer failure includes HTML | Do not store/log raw exception or HTML |
| Scanner payload leaks through inspect | Redact from Artifact, Document, Error inspect |
| Agent adds route | Reject; route belongs to later slice |
| Agent queries TicketIssue directly | Reject; use ArtifactResolver |
| Event metadata missing | Omit PDF fields cleanly |
| Display scalar contains HTML | Escape values |
| Massive PDF load | No public route; future delivery must queue through Oban |
| PDF staleness after revocation | No cache/persistence in VS-24B |

---

## 8. Performance And Scaling Review

| Data | Layer | Rule |
|---|---|---|
| ArtifactResolver reads | Cold Postgres | Existing indexed delivery-token-hash path |
| Artifact | Request-local memory | No cache |
| QR/SVG | Request-local memory | No cache |
| HTML | Request-local memory | No logging |
| PDF bytes | Request-local memory | No persistence |
| Renderer | Bounded OS/process resource | Timeouts + small pool |

No Redis/Cachex in VS-24B.

PDF rendering is not safe as an unbounded public synchronous path. Since VS-24B adds no route, high-concurrency public traffic is avoided. VS-24C delivery should use Oban, rate limits, bounded renderer concurrency, and explicit storage/TTL design if persistence is introduced.

---

## 9. Security / Privacy Review

### Allowed In Customer PDF

```text
event_name
event_date
event_time
event_location
entrance_name
attendee_name
ticket_type
scanner_payload as QR/readable code
support_message
issued_at
delivery_expires_at
```

### Forbidden In Structs/Logs/Errors/Metadata

```text
delivery token
delivery token hash
QR token hash
ticket URL
payment URL
Paystack access code
raw provider payload
phone
email
buyer_phone
buyer_email
recipient
provider message body
provider request body
authorization_url
access_code
raw HTML
raw PDF bytes through inspect/logs
```

### Inspect Rules

- `Artifact.inspect/1` must continue redacting scanner payload and display scalars.
- `ArtifactError.inspect/1` stays generic.
- `PdfTicket.Document.inspect/1` must never print bytes or content-derived scalars.
- `PdfTicket.Error.inspect/1` must never print raw renderer details or HTML.

---

## 10. Test Plan

### Artifact Extension

- valid artifact includes event date/time/location/entrance when present;
- nil metadata is valid;
- `inspect(artifact)` does not leak display values or scanner payload;
- invalid state tests remain green.

### PDF Boundary

- valid delivery token returns `Document`;
- valid artifact generates PDF without DB access;
- invalid/revoked/expired/not-ready/not-scannable states return `ArtifactError`;
- renderer is not called for invalid states;
- renderer failure returns safe `PdfTicket.Error`;
- document/error inspect redacts bytes/scanner payload/raw HTML/tokens/hashes/URLs/phone/email;
- no mutation of ticket/attendee/order/payment/delivery rows.

### Template / QR

- escapes display scalars;
- includes QR image and readable scanner code;
- omits nil fields cleanly;
- no external `http://` or `https://` references;
- deterministic output for fixed artifact/generated_at.

### Regression

- `TicketPage.resolve/1` returns exactly six legacy keys;
- secure controller tests remain green;
- VS-22 checkout-to-scanner and revocation E2E remain green.

---

## 11. Verification Commands

```bash
mix deps.get
mix format
mix test test/fastcheck/tickets/artifact_resolver_test.exs
mix test test/fastcheck/tickets/pdf_ticket/template_test.exs
mix test test/fastcheck/tickets/pdf_ticket_test.exs
mix test test/fastcheck/sales/ticket_page_test.exs
mix test test/fastcheck_web/controllers/secure_ticket_controller_test.exs
mix test test/fastcheck/sales/e2e/checkout_to_scanner_test.exs
mix test test/fastcheck/sales/e2e/revocation_scanner_visibility_test.exs
mix precommit
```

Do not make local Chrome/Ghostscript mandatory for default precommit unless CI already supports them.

---

## 12. What Success Looks Like

```text
A valid artifact generates a customer-safe PDF document.
Invalid artifacts do not generate PDFs.
PDF generation has no mutations.
TicketPage and secure web route behavior remain unchanged.
PDF bytes are not stored or delivered yet.
Inspect/logs/errors do not leak scanner payloads or protected internals.
VS-24C can later deliver PDFs without adding ticket-validity logic.
```
