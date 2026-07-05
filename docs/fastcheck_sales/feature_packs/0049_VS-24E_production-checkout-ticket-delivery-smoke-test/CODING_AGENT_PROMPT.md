# Coding-Agent Prompt — VS-24E Production Checkout And Ticket Delivery Smoke Test

You are working in `JCSchoeman96/FastCheckin` on current `main`.

Create VS-24E — Production Checkout and Ticket Delivery Smoke Test.

This is a validation/runbook slice, not a feature slice.

## Goal

Create a complete docs-only smoke-test plan and evidence pack that validates the
current customer money-to-ticket loop before Apple Wallet and Google Wallet work
begins.

## Current Repo Truth

- VS-24D is merged into `main`.
- Customer-facing delivery currently sends a secure ticket link, not a PDF
  attachment.
- PDF ticket generation exists as dashboard-only/manual staff download.
- Dashboard PDF download does not send messages, store PDFs, create delivery
  attempts, or resolve public delivery tokens.
- `PaymentFlow` is only an interface orchestrator.
- Paystack webhook ingress must not verify payment or issue tickets directly.
- `PaymentVerification` is the server-side verification authority.
- `IssueTicketsWorker` must delegate to `FastCheck.Tickets.Issuer`.
- Secure ticket controller and ticket page are read-only display surfaces.
- Scanner authority must remain unchanged.
- Verified resend requires backend identity match and email OTP.

## Hard Rules

- Do not change production code.
- Do not change config, migrations, router, workers, controllers, payment
  modules, ticket issuance modules, scanner modules, refund/revocation modules,
  wallet modules, delivery behavior, Android code, assets, or tests.
- Do not add Apple Wallet or Google Wallet.
- Do not add customer PDF attachment delivery.
- Do not add new PDF delivery behavior.
- Do not expose or record raw payment URLs, Paystack access codes, delivery
  tokens, token hashes, QR hashes, OTPs, raw phone numbers, emails, provider
  payloads, or screenshots containing those values.
- Use redacted evidence only.
- If the smoke test finds a bug, document it and stop. Do not fix it inside
  VS-24E unless explicitly instructed.

## Deliverables

Create:

- `docs/fastcheck_sales/feature_packs/0049_VS-24E_production-checkout-ticket-delivery-smoke-test/VS-24E-FEATURE_PACK.md`
- `docs/fastcheck_sales/feature_packs/0049_VS-24E_production-checkout-ticket-delivery-smoke-test/CODING_AGENT_PROMPT.md`
- `docs/fastcheck_sales/feature_packs/0049_VS-24E_production-checkout-ticket-delivery-smoke-test/TOON_PROMPTS.md`
- `docs/fastcheck_sales/feature_packs/0049_VS-24E_production-checkout-ticket-delivery-smoke-test/ACCEPTANCE_CHECKLIST.md`
- `docs/fastcheck_sales/feature_packs/0049_VS-24E_production-checkout-ticket-delivery-smoke-test/EVIDENCE_TEMPLATE.md`
- `docs/fastcheck_sales/feature_packs/0049_VS-24E_production-checkout-ticket-delivery-smoke-test/pack.json`
- `docs/fastcheck_sales/runbooks/VS-24E_PRODUCTION_CHECKOUT_TICKET_DELIVERY_SMOKE_TEST.md`
- `docs/fastcheck_sales/runbooks/VS-24E_FAILURE_MATRIX.md`
- `docs/fastcheck_sales/runbooks/VS-24E_PRODUCTION_LOW_VALUE_SMOKE.md`

Update:

- `docs/fastcheck_sales/runbooks/README.md`

If `0049` conflicts, use the next available ordinal. Do not rename existing pack
folders without explicit approval.

## Required Runbook Coverage

The runbook must validate:

- WhatsApp checkout.
- Paystack payment link.
- Paystack webhook.
- Server-side Paystack verification.
- Ticket issuance.
- WhatsApp secure ticket link.
- Secure ticket page.
- Dashboard/manual PDF download.
- Scanner sync and scan.
- Resend through WhatsApp + email OTP.
- Admin ops dashboard and audit timeline.
- Duplicate webhook and duplicate worker idempotency.
- Revoked, refunded, cancelled, archived, expired, and not-scannable fail-closed
  behavior.
- Log and evidence redaction.

## Verification Commands To List

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

Run existing tests only as verification. Do not add new tests unless explicitly
requested.

## Final Review

Before finishing:

1. Run `git diff --stat`.
2. Run `git diff --name-only`.
3. Confirm the diff contains only:
   - `docs/fastcheck_sales/feature_packs/...`
   - `docs/fastcheck_sales/runbooks/...`
4. If any `lib/`, `config/`, `priv/repo/migrations/`, `assets/`, router,
   controller, worker, payment, ticket, scanner, wallet, Android, or test file
   changes are present, stop and ask for review before proceeding.

Final response must include:

- Exact files changed.
- Verification commands run.
- Manual smoke steps still requiring a human/operator.
- Pass/fail gates before VS-25A Apple Wallet may start.
