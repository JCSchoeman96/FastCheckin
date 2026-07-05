# VS-24E — Production Checkout And Ticket Delivery Smoke Test

## Summary

VS-24E is a docs-only production-readiness validation slice. It proves the
existing customer money-to-ticket loop before Apple Wallet or Google Wallet work
starts.

Validated path:

```text
WhatsApp checkout
-> Paystack payment link
-> Paystack webhook receipt
-> server-side Paystack verification
-> ticket issuance
-> WhatsApp secure ticket link
-> secure ticket page
-> dashboard/manual PDF download
-> scanner sync and scan
-> verified resend through WhatsApp + email OTP
```

This slice does not add features. It creates the runbooks, failure matrix,
acceptance checklist, and redacted evidence template needed to run and sign off
the existing production-readiness smoke.

## Current Repo Truth

- VS-24D is merged into `main` at
  `e03e6b33a66e7e82d8efa900a755e3123dc58be2`.
- The existing Sandbox Dress Rehearsal states that VS-22 E2E tests are the
  source of truth for operation order.
- The existing Go/No-Go Checklist already covers code/CI, secrets, database,
  Redis, Oban, Paystack, WhatsApp, sales events/offers, ticket issuance, secure
  ticket page, scanner, admin/manual review, ops dashboard, logging, and
  rollback readiness.
- Customer-facing ticket delivery currently sends a secure ticket link.
- Customer-facing delivery does not currently send PDF attachments.
- PDF generation is available through an authenticated dashboard/manual staff
  download route.
- Dashboard PDF download does not send messages, store PDFs, create delivery
  attempts, or resolve public delivery tokens.
- `PaymentFlow` is an interface orchestrator; it does not verify payments,
  issue tickets, mutate scanner state, or call provider HTTP clients.
- Paystack webhook ingress accepts signed callbacks, delegates ingestion, and
  returns quickly. Webhook receipt alone is not payment authority.
- `PaymentVerification` is the server-side Paystack verification authority.
- `IssueTicketsWorker` delegates ticket creation to `FastCheck.Tickets.Issuer`.
- The issuer requires verified successful payment plus paid checkout before
  issuing and uses duplicate-safe database authority.
- Ticket-link delivery sends secure ticket page links, records delivery
  attempts, and uses outbound dedupe.
- Secure ticket pages are possession-token based, read-only display surfaces.
- Scanner authority remains unchanged on the existing attendee/mobile scan path.
- Verified resend requires backend identity match and email OTP before queueing
  secure ticket link delivery.

## Goal

Produce a signed VS-24E evidence pack proving FastCheck is safe for real
customers before wallet artifacts are added.

A successful smoke proves:

1. A customer can start from WhatsApp.
2. The customer can select an event and ticket.
3. The customer receives the correct Paystack payment link.
4. Paystack webhook reaches the app.
5. Payment is verified server-side.
6. One paid unit creates one ticket issue and one attendee.
7. The customer receives one secure ticket link.
8. The secure ticket page opens.
9. Authenticated staff can manually download the dashboard PDF.
10. Scanner sync sees the attendee and the valid ticket scans.
11. Revoked, refunded, cancelled, archived, expired, and not-scannable paths
    fail closed.
12. Verified resend works only after identity match and email OTP.
13. No protected values leak into messages, logs, audit rows, evidence, or PR
    notes.

## Non-Goals

VS-24E must not:

- Add Apple Wallet or Google Wallet.
- Add customer PDF attachment delivery.
- Add new PDF delivery, PDF storage, public PDF routes, or customer PDF resend.
- Change checkout, payment, Paystack initialization, webhook, or verification
  behavior.
- Change ticket issuance, attendee creation, scanner, revocation, refund, or
  resend behavior.
- Change production code, config, migrations, router, controllers, workers,
  LiveViews, assets, tests, Android code, or dependencies.
- Add new APIs or public interfaces.
- Simulate flash-sale load or run load tests.
- Fix bugs found during smoke execution. Bugs must be documented and the smoke
  must stop unless explicit follow-up approval is given.

## Dependencies

- VS-22 E2E sandbox tests and operation order.
- VS-23B Final Core Launch Runbook.
- VS-23C Final WhatsApp Launch Runbook.
- Sandbox Dress Rehearsal.
- Go/No-Go Checklist.
- VS-24A ticket artifact contract.
- VS-24B/VS-24C PDF generation and dashboard/manual PDF download repo truth.
- VS-24D verified resend and audit traceability repo truth.

## Scope

Create:

- VS-24E feature pack.
- Coding-agent prompt.
- TOON prompts.
- Acceptance checklist.
- Redacted evidence template.
- Production checkout and ticket delivery smoke runbook.
- Failure matrix.
- Optional low-value production smoke checklist.
- Runbooks README index links.

## Domain Model

Domain: production checkout and ticket delivery smoke-test validation.

Entities observed:

- Event.
- Ticket offer.
- Redis inventory hold / availability state.
- WhatsApp conversation.
- Checkout session.
- Order.
- Order line.
- Payment attempt.
- Payment event.
- Oban job.
- Ticket issue.
- Attendee.
- Delivery attempt.
- Ticket resend challenge.
- Audit timeline entry.
- Secure ticket page result.
- PDF document.
- Scanner/mobile sync result.

Relationships observed:

- Event -> ticket offer.
- Ticket offer -> checkout session / order line.
- Conversation -> checkout session / order / payment attempt.
- Order -> order line.
- Order -> payment attempt.
- Payment attempt -> payment event.
- Order -> ticket issue.
- Ticket issue -> attendee.
- Order/ticket issue -> delivery attempt.
- Ticket resend challenge -> verified resend delivery attempt.
- Ticket issue -> secure ticket page.
- Ticket issue -> dashboard/manual PDF artifact.
- Attendee/ticket issue -> scanner visibility.

## Systems To Validate

1. Runtime environment and secrets.
2. Database migrations and PgBouncer compatibility.
3. Redis inventory holds, WhatsApp sessions, outbound dedupe, and availability.
4. Oban queues and workers.
5. WhatsApp inbound and outbound.
6. Checkout/order/session creation.
7. Paystack payment initialization.
8. Paystack webhook ingestion.
9. Server-side payment verification.
10. Ticket issuance.
11. Secure ticket link delivery.
12. Secure ticket page.
13. Dashboard-only PDF download.
14. Scanner/mobile sync and scan.
15. Resend with email OTP.
16. Admin ops dashboard and audit timeline.
17. Log/security redaction.

## Invariants

- Webhook receipt alone never issues tickets.
- Payment must be verified server-side before issuance.
- Ticket issuance must happen through `FastCheck.Tickets.Issuer`.
- One paid unit creates one attendee and one ticket issue.
- Duplicate webhook does not duplicate payment effects.
- Duplicate issuance does not duplicate attendees or tickets.
- Ticket link delivery does not expose token hash or QR hash.
- Secure ticket page is read-only.
- PDF download is dashboard-only/manual staff delivery today.
- Customer delivery is secure ticket link today, not PDF attachment.
- Resend requires backend identity match and email OTP.
- Revoked, refunded, cancelled, archived, expired, and not-scannable tickets
  cannot scan or be resent as valid.
- Protected values must not appear in messages, logs, audit rows, evidence,
  screenshots, or PR notes.

## Acceptance Criteria

- Feature pack and runbooks are added.
- `pack.json` is present and follows sibling feature-pack convention.
- Runbooks README links the new VS-24E runbooks.
- No production behavior changes are included.
- Sandbox/test-mode smoke procedure is complete.
- Optional low-value production smoke procedure is complete.
- Evidence template forbids protected values.
- Failure matrix covers payment, webhook, issuance, delivery, scanner, PDF, and
  resend cases.
- Verification commands are listed.
- Go/No-Go gates are explicit.
- The runbook states that current customer delivery is secure ticket link and
  PDF is dashboard/manual staff download.
- VS-25A wallet work is blocked until VS-24E evidence passes or risk is
  formally accepted.

## Verification

Recommended automated verification before running the manual smoke:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/fastcheck/messaging/whatsapp/e2e/whatsapp_paid_core_test.exs
mix test test/fastcheck/sales/e2e/checkout_to_scanner_test.exs
mix test test/fastcheck/sales/e2e/payment_failure_paths_test.exs
mix test test/fastcheck/sales/e2e/revocation_scanner_visibility_test.exs
mix test test/fastcheck/sales/payments/payment_verification_test.exs
mix test test/fastcheck/sales/payments/payment_verification_idempotency_test.exs
mix test test/fastcheck/sales/payments/paystack_initialization_idempotency_test.exs
mix test test/fastcheck/sales/payments/webhook_ingestion_test.exs
mix test test/fastcheck_web/controllers/webhooks/paystack_controller_test.exs
mix test test/fastcheck/workers/issue_tickets_worker_test.exs
mix test test/fastcheck/workers/send_whatsapp_payment_link_worker_test.exs
mix test test/fastcheck/workers/send_whatsapp_ticket_link_worker_test.exs
mix test test/fastcheck_web/controllers/secure_ticket_controller_test.exs
mix test test/fastcheck_web/controllers/sales/ticket_pdf_controller_test.exs
mix test test/fastcheck/messaging/whatsapp/resend_ticket_e2e_test.exs
mix test test/fastcheck/messaging/whatsapp/resend_delivery_flow_test.exs
mix test test/fastcheck/tickets/resend/otp_test.exs
mix test test/fastcheck/tickets/scanner_visibility_test.exs
mix sobelow --exit --compact
mix precommit
```

For this docs-only implementation PR, `mix format --check-formatted` and
`mix precommit` are the required local gates unless the implementer reports a
specific environment blocker.

## Go/No-Go

VS-25A Apple Wallet and Google Wallet work may start only when one of these is
true:

- VS-24E sandbox/test-mode smoke passed and evidence is signed off.
- Optional low-value production smoke passed and evidence is signed off, if the
  launch owner required it.
- A launch owner explicitly risk-accepted any skipped or failed non-critical
  smoke step in writing.

Stop-ship failures include:

- Payment mismatch accepted as paid.
- Webhook receipt issuing tickets without server-side verification.
- Duplicate ticket issue or attendee for one paid unit.
- Customer receives or evidence assumes PDF attachment delivery.
- Secure ticket link or token/hash/OTP/PII leakage.
- Scanner accepts revoked, refunded, cancelled, archived, expired, or
  not-scannable ticket.
- Resend works without identity match and email OTP.
- Operator cannot observe required states in ops dashboard or audit timeline.
