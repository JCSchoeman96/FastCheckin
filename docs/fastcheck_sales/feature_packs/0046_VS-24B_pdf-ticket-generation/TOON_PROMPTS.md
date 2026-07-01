# VS-24B — TOON Prompts

| Field | Content |
|---|---|
| Task | Implement VS-24B as one PDF ticket generation slice. |
| Objective | Add PDF generation as a consumer of the VS-24A artifact contract. |
| Output | PDF modules, tests, config/dependency updates, and docs under `0046_VS-24B_pdf-ticket-generation`. |
| Note | No routes, migrations, caches, persistence, delivery, WhatsApp/email, Apple Wallet, Google Wallet, payment, issuer, scanner, revocation, or token rotation changes. |

| Field | Content |
|---|---|
| Task | Extend `FastCheck.Tickets.Artifact` with PDF-safe event metadata. |
| Objective | Give PDF/future renderers event date/time/location without re-querying Event. |
| Output | Updated `lib/fastcheck/tickets/artifact.ex`. |
| Note | Add only optional `event_date`, `event_time`, `event_location`, `entrance_name`. Update custom `Inspect` to redact values. No IDs, URLs, phones, emails, payment/provider fields, or raw structs. |

| Field | Content |
|---|---|
| Task | Populate new Artifact metadata in `ArtifactResolver`. |
| Objective | Keep ArtifactResolver as the only customer-facing projection boundary. |
| Output | Updated `lib/fastcheck/tickets/artifact_resolver.ex`. |
| Note | Copy from loaded Event only. No extra resolver queries beyond existing event lookup. No writes. Do not use `TicketIssue.scanner_status` as authority. |

| Field | Content |
|---|---|
| Task | Preserve `TicketPage.resolve/1` legacy contract. |
| Objective | Keep secure ticket page unchanged while artifact grows for PDF. |
| Output | Updated tests and verified `lib/fastcheck/sales/ticket_page.ex`. |
| Note | Result keys remain exactly `state`, `event_name`, `attendee_name`, `ticket_type`, `qr_payload`, `support_message`. Do not leak PDF fields. |

| Field | Content |
|---|---|
| Task | Add PDF/QR dependencies and test-safe config. |
| Objective | Enable real PDF generation without making unit tests depend on local Chrome/Ghostscript. |
| Output | Updated `mix.exs`, `mix.lock`, `config/config.exs`, `config/test.exs`, and possibly `lib/fastcheck/application.ex`. |
| Note | Recommended: `chromic_pdf` behind renderer behaviour and `eqrcode` for QR. Test config must use fake renderer. Bound renderer concurrency/timeouts. |

| Field | Content |
|---|---|
| Task | Create `PdfTicket.Document`. |
| Objective | Return generated PDF bytes through a safe result contract. |
| Output | `lib/fastcheck/tickets/pdf_ticket/document.ex`. |
| Note | Fields: `bytes`, `content_type`, `filename`, `byte_size`, `sha256`, `generated_at`. Implement custom `Inspect` that redacts bytes and content-derived scalars. Filename must be generic/PII-safe. |

| Field | Content |
|---|---|
| Task | Create `PdfTicket.Error`. |
| Objective | Safely represent renderer failure states. |
| Output | `lib/fastcheck/tickets/pdf_ticket/error.ex`. |
| Note | States: `:renderer_unavailable`, `:render_failed`, `:invalid_artifact`. Do not expose raw exceptions, HTML, scanner payload, token/hash, URL, phone, email, payment/provider values. Custom `Inspect` required. |

| Field | Content |
|---|---|
| Task | Create `PdfTicket.QrCode`. |
| Objective | Convert `artifact.scanner_payload` into deterministic PDF scan material. |
| Output | `lib/fastcheck/tickets/pdf_ticket/qr_code.ex`. |
| Note | Input is artifact scanner payload only. Do not create new QR tokens, use QR hashes, or change `QrPayload` format. Do not log payload. |

| Field | Content |
|---|---|
| Task | Create `PdfTicket.Template`. |
| Objective | Build deterministic escaped HTML for PDF rendering. |
| Output | `lib/fastcheck/tickets/pdf_ticket/template.ex`. |
| Note | Inline CSS only. Escape all display scalars. Include allowed customer fields and QR/readable code. No external URLs/scripts/fonts/images, raw structs, tokens, hashes, phones, emails, payment/provider data. |

| Field | Content |
|---|---|
| Task | Create renderer behaviour and production adapter. |
| Objective | Isolate PDF library usage and keep tests deterministic. |
| Output | `lib/fastcheck/tickets/pdf_ticket/renderer.ex` and `lib/fastcheck/tickets/pdf_ticket/chromic_renderer.ex`. |
| Note | Use official `chromic_pdf` docs. Do not call renderer from controllers/workers. Return safe errors on unavailable/failure. Never log HTML/PDF bytes. |

| Field | Content |
|---|---|
| Task | Create fake renderer for tests. |
| Objective | Let focused tests and precommit run without Chrome/Ghostscript. |
| Output | `test/support/fastcheck/tickets/pdf_ticket/fake_renderer.ex`. |
| Note | Fake returns deterministic minimal PDF bytes and supports assertions for called/not-called behavior. |

| Field | Content |
|---|---|
| Task | Create `FastCheck.Tickets.PdfTicket` boundary. |
| Objective | Expose safe PDF generation from delivery token or artifact. |
| Output | `lib/fastcheck/tickets/pdf_ticket.ex`. |
| Note | `generate_from_delivery_token/2` calls ArtifactResolver; invalid states return ArtifactError and do not call renderer. `generate_from_artifact/2` does not touch DB. No writes, storage, routes, delivery, token rotation, payment, issuer, scanner, revocation calls. |

| Field | Content |
|---|---|
| Task | Add artifact/PDF/template tests. |
| Objective | Prove validity, privacy, no mutation, and regressions. |
| Output | Updated artifact/TicketPage tests and new `pdf_ticket_test.exs` + `template_test.exs`. |
| Note | Cover valid generation, invalid states, renderer no-call/failure, inspect redaction, HTML escaping, forbidden data absence, no external URLs, no row mutation, and legacy TicketPage keys. |

| Field | Content |
|---|---|
| Task | Add VS-24B docs and metadata. |
| Objective | Keep feature-pack convention aligned. |
| Output | README, feature pack, TOON prompts, coding-agent prompt, pack.json, and post-merge handoff template under `0046_VS-24B_pdf-ticket-generation`. |
| Note | Do not add `docs/fastcheck_sales/handoffs/VS-24B_IMPLEMENTATION_HANDOFF.md` during implementation PR. |

| Field | Content |
|---|---|
| Task | Run verification. |
| Objective | Prove VS-24B is safe to open/merge. |
| Output | Passing command output in PR description. |
| Note | Run deps, format, focused PDF/artifact/TicketPage/controller/E2E tests, then `mix precommit`. |
