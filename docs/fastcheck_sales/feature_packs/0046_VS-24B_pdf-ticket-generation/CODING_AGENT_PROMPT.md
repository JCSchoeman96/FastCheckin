# Coding-Agent Prompt — VS-24B PDF Ticket Generation

Implement VS-24B for `JCSchoeman96/FastCheckin` issue #439.

## Goal

Generate customer-facing PDF tickets from the merged VS-24A artifact contract.

## Core Rule

PDF generation must consume `FastCheck.Tickets.ArtifactResolver` / `%FastCheck.Tickets.Artifact{}`. Do not query `TicketIssue`, `Attendee`, `Order`, payment, scanner, or revocation logic directly to decide validity.

## Hard No

Do not change controller/template/router, payment, issuer, scanner, revocation/refund, WhatsApp/delivery, token rotation, or secure ticket page behavior. Do not add PDF route, storage, migration, delivery, Apple Wallet, Google Wallet, or handoff under `docs/fastcheck_sales/handoffs/`.

## Required Work

1. Extend `Artifact` with optional `event_date`, `event_time`, `event_location`, `entrance_name` and populate from `Event` in `ArtifactResolver`.
2. Preserve `TicketPage.resolve/1` result keys exactly: `state`, `event_name`, `attendee_name`, `ticket_type`, `qr_payload`, `support_message`.
3. Add PDF modules:
   - `FastCheck.Tickets.PdfTicket`
   - `PdfTicket.Document`
   - `PdfTicket.Error`
   - `PdfTicket.Template`
   - `PdfTicket.QrCode`
   - `PdfTicket.Renderer`
   - `PdfTicket.ChromicRenderer`
   - fake renderer in `test/support`.
4. Recommended dependencies: `chromic_pdf` for HTML-to-PDF behind the renderer behaviour and `eqrcode` for QR scan material.
5. Default tests must use fake renderer and must not require local Chrome/Ghostscript.
6. Add docs under `docs/fastcheck_sales/feature_packs/0046_VS-24B_pdf-ticket-generation/`.

## Public API

Expose:

```text
generate_from_delivery_token(raw_token, opts \ [])
generate_from_artifact(%FastCheck.Tickets.Artifact{} = artifact, opts \ [])
```

Return:

```text
{:ok, %FastCheck.Tickets.PdfTicket.Document{}}
{:error, %FastCheck.Tickets.ArtifactError{}}
{:error, %FastCheck.Tickets.PdfTicket.Error{}}
```

Invalid artifact states must return `ArtifactError` and must not call renderer.

## Security

PDF bytes may contain scanner payload because the customer needs scan material. But scanner payload, tokens, hashes, raw HTML, PDF bytes, phone, email, URLs, Paystack/provider data must not leak through logs, errors, filenames, or `inspect/1`.

Custom `Inspect` required for:

- `Artifact` after metadata extension;
- `PdfTicket.Document`;
- `PdfTicket.Error`.

## Tests

Add/update tests for:

- artifact metadata extension;
- legacy TicketPage keys;
- valid PDF generation;
- invalid/revoked/expired/not-ready/not-scannable states;
- renderer no-call on invalid artifact;
- renderer failure;
- inspect redaction;
- HTML escaping;
- no external URLs;
- no forbidden internals;
- no mutation of ticket/attendee/order/payment/delivery rows;
- existing secure controller and VS-22 E2E tests.

## Verification

Run:

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

## PR Must State

No migrations, routes, storage, delivery, controller/template changes, PDF delivery, Apple/Google Wallet, or payment/issuer/scanner/revocation behavior changes. PDF consumes ArtifactResolver. TicketPage legacy shape preserved. Inspect redaction added. Default tests do not require Chrome/Ghostscript.
