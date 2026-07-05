# VS-24E Production Checkout And Ticket Delivery Smoke Test

Use this runbook after automated checks are green and before any VS-25 wallet
work starts.

VS-22 E2E tests remain the source of truth for operation order. This runbook is
the manual evidence path for the same money-to-ticket loop.

## Scope

Validate the current production-like path:

```text
WhatsApp -> Paystack -> server-side verification -> ticket issuance
-> secure ticket link -> secure ticket page -> dashboard/manual PDF download
-> scanner -> verified resend
```

Customer delivery expectation:

- Customer receives a secure ticket link.
- Secure ticket page opens from that link.
- PDF is dashboard-only/manual staff download.
- Customer PDF attachment delivery is not expected and must not be claimed.

## Protected-Value Policy

Never record protected values in evidence, logs, screenshots, PR notes, issue
comments, or chat.

Forbidden values:

- Raw payment URL.
- Paystack access code.
- Ticket link.
- Delivery token.
- Delivery token hash.
- QR hash.
- OTP.
- Phone number.
- Email address.
- WhatsApp `wa_id`.
- Raw provider payload.
- Raw internal structs.
- Screenshots containing any protected value.

Use IDs, statuses, redacted suffixes, timestamps, and operator notes only.

## Stop Conditions

Stop the smoke immediately if any of these occur:

- Payment mismatch is accepted as verified paid.
- Webhook receipt alone issues tickets.
- More than one ticket issue or attendee is created for one paid unit.
- Customer receives or evidence assumes a PDF attachment.
- Secure ticket link, token, hash, OTP, payment URL, or PII leaks.
- Scanner accepts a revoked, refunded, cancelled, archived, expired, or
  not-scannable ticket.
- Resend works without identity match and email OTP.
- Operator cannot observe required state in ops dashboard or audit timeline.

If a smoke step fails, document the failure and stop. Do not fix bugs inside
VS-24E unless explicitly instructed.

## 1. Environment Preflight

Record evidence in the VS-24E evidence template using redacted IDs only.

- Action: Confirm current release candidate is based on current `main`.
- Expected result: Deployed commit SHA is at or after the approved release SHA.
- Where to verify: GitHub checks, deployment metadata, `git status --short --branch`.
- Failure response: Stop; do not run payment smoke on an unknown release.

- Action: Confirm CI is green.
- Expected result: No failing checks for release candidate.
- Where to verify: GitHub checks.
- Failure response: Stop; resolve CI outside VS-24E.

- Action: Confirm database connectivity, migrations, and pooling compatibility.
- Expected result: App can query sales, payment, ticket, attendee, and audit
  tables; no pending migrations remain; pooling/prepared-statement mode matches
  deployment.
- Where to verify: Deployment health check, migration status, ops dashboard.
- Failure response: Stop; do not run broad production DB scans.

- Action: Confirm Redis is reachable.
- Expected result: Inventory availability, checkout holds, WhatsApp sessions,
  outbound dedupe, and rate-limit state are available.
- Where to verify: Health check and approved Redis operational checks.
- Failure response: Stop new checkouts until Redis health is confirmed.

- Action: Confirm Oban is running.
- Expected result: Paystack webhook, payment verification, ticket issuance,
  checkout expiry, payment link, and ticket link workers are processing.
- Where to verify: Ops dashboard and Oban admin surface if available.
- Failure response: Stop; do not start manual payment if workers are paused.

- Action: Confirm Paystack mode deliberately.
- Expected result: Sandbox/test-mode for sandbox smoke; live mode only for
  approved low-value production smoke.
- Where to verify: Safe config display or deployment metadata. Do not print
  secrets.
- Failure response: Stop if mode is ambiguous.

- Action: Confirm Meta/WhatsApp mode deliberately.
- Expected result: Inbound and outbound are enabled for the intended environment.
- Where to verify: Safe config display, Meta dashboard, and app health.
- Failure response: Stop if customer messages might go to wrong environment.

- Action: Confirm dashboard authentication works.
- Expected result: Assigned operator can open `/dashboard/sales/ops`,
  `/dashboard/sales/orders/:id`, and audit timeline surfaces.
- Where to verify: Browser session.
- Failure response: Stop; operator visibility is required.

- Action: Confirm scanner/mobile configuration.
- Expected result: Approved scanner device/session can authenticate for the test
  event and sync attendees.
- Where to verify: Scanner app and mobile API health.
- Failure response: Stop scanner validation until device/session is ready.

## 2. Sandbox/Test-Mode Happy Path

### 2.1 Setup Test Event And Offer

- Action: Select a sandbox/internal event and active WhatsApp ticket offer.
- Expected result: Event and offer are active; inventory availability matches
  approved test quantity.
- Where to verify: Ops dashboard, offer admin view, approved Redis check.
- Evidence: event label, offer label, redacted availability status.
- Failure response: Stop; do not test against production launch event by
  accident.

### 2.2 Start WhatsApp Checkout

- Action: Send an approved test inbound WhatsApp message.
- Expected result: Conversation starts or resumes in the checkout flow.
- Where to verify: Conversation state, ops dashboard, audit timeline.
- Evidence: conversation ID and state only.
- Failure response: Inspect inbound webhook/session state outside VS-24E.

- Action: Select event, ticket offer, quantity, buyer details, and confirmation.
- Expected result: Checkout session and order are created with WhatsApp source.
- Where to verify: Order operations page and audit timeline.
- Evidence: checkout session ID, order ID, redacted order suffix.
- Failure response: Stop if checkout/order state is missing or inconsistent.

### 2.3 Payment Link

- Action: Allow payment-link worker to send the Paystack payment message.
- Expected result: Customer receives one payment message.
- Where to verify: Delivery status, Oban job, audit timeline.
- Evidence: payment attempt ID, payment-link job ID, sent status.
- Failure response: Stop if duplicate sends occur or no message is sent.

- Action: Verify payment link points to the correct Paystack mode and reference.
- Expected result: Correct mode, expected amount, currency, and order reference.
- Where to verify: Paystack dashboard and local payment attempt.
- Evidence: payment attempt ID and redacted reference suffix only.
- Failure response: Stop on wrong amount, currency, environment, or reference.

Do not record the raw payment URL or access code.

### 2.4 Paystack Payment And Webhook

- Action: Complete Paystack sandbox/test payment.
- Expected result: Paystack records payment for intended reference in intended
  mode.
- Where to verify: Paystack dashboard and local payment attempt.
- Evidence: payment attempt ID and redacted reference suffix only.
- Failure response: Stop; provider UI alone is not payment authority.

- Action: Confirm Paystack webhook reaches app.
- Expected result: Payment event row is stored and visible through safe operator
  surfaces.
- Where to verify: Ops dashboard, payment event, audit timeline.
- Evidence: payment event ID and received status.
- Failure response: Inspect webhook URL, signature, logs, and provider retry
  state outside VS-24E.

### 2.5 Server-Side Verification

- Action: Let the verification worker or approved verification path run.
- Expected result: Server-side verification succeeds; amount, currency,
  reference, provider status, and event ownership match.
- Where to verify: Order operations page, payment attempt, audit timeline.
- Evidence: payment attempt ID, verification job ID, verified status.
- Failure response: Stop; do not issue tickets from webhook receipt alone.

### 2.6 Ticket Issuance

- Action: Let `IssueTicketsWorker` process the verified paid order.
- Expected result: One ticket issue and one attendee are created per paid unit.
- Where to verify: Order page, ticket issue, attendee record, audit timeline.
- Evidence: order ID, ticket issue ID, attendee ID, issuance job ID.
- Failure response: Stop on duplicate or missing ticket/attendee.

- Action: Re-run or replay the approved duplicate worker check in sandbox only.
- Expected result: No duplicate ticket issue or attendee is created.
- Where to verify: DB read-only counts, order page, audit timeline.
- Evidence: existing ticket issue ID and attendee ID remain the only records.
- Failure response: Stop; duplicate issuance is a wallet-blocking defect.

### 2.7 Secure Ticket Link Delivery

- Action: Let ticket-link worker send the customer ticket message.
- Expected result: Customer receives one secure ticket link message.
- Where to verify: Delivery attempt, Oban job, audit timeline.
- Evidence: delivery attempt ID, ticket-link job ID, sent status.
- Failure response: Stop on duplicate link send or no delivery.

Do not record the ticket link or delivery token.

### 2.8 Secure Ticket Page

- Action: Open the received secure ticket link.
- Expected result: Secure ticket page renders valid ticket state and no internal
  token/hash values.
- Where to verify: Browser page and safe page headers where applicable.
- Evidence: ticket issue ID, page opened status, timestamp.
- Failure response: Stop; inspect token state without pasting link into logs.

### 2.9 Dashboard/Manual PDF Download

- Action: Authenticated staff opens the order page and downloads PDF through the
  dashboard/manual route.
- Expected result: Response is `application/pdf` attachment with private/no-cache
  headers and customer-safe ticket details.
- Where to verify: Browser developer tools or safe operator observation.
- Evidence: dashboard PDF request correlation, HTTP status, content type.
- Failure response: Stop PDF validation; do not add customer delivery behavior.

Rules:

- Do not expect customer PDF attachment delivery.
- Do not send PDF to customer during this check.
- Do not create delivery attempts for the PDF check.
- Do not store PDFs.
- Do not expose public delivery tokens.
- Do not record ticket code, QR material, token, or screenshots containing them.

### 2.10 Scanner/Mobile Sync And Valid Scan

- Action: Authenticate approved scanner device/session for the test event.
- Expected result: Scanner auth succeeds for event scope.
- Where to verify: Scanner app or mobile API.
- Evidence: scanner session/device label and status only.
- Failure response: Stop scanner validation until auth is fixed.

- Action: Run attendee sync.
- Expected result: Issued attendee is visible to scanner/mobile sync.
- Where to verify: Scanner app, mobile sync response, ops dashboard.
- Evidence: attendee ID and sync status only.
- Failure response: Stop; scanner visibility is wallet-blocking.

- Action: Scan the valid ticket once according to current scanner rules.
- Expected result: Scan succeeds and server persists accepted result.
- Where to verify: Scanner app, mobile scan endpoint, order/audit views.
- Evidence: scan result ID/correlation and accepted status.
- Failure response: Stop; backend scanner authority must remain correct.

### 2.11 Fail-Closed Scanner Checks

Run destructive revocation/refund checks only in sandbox/test-mode or if explicit
production approval exists.

- Action: Revoke, refund/cancel, or mark not-scannable through approved operator
  path.
- Expected result: Ticket/attendee scanner visibility changes and invalidation
  is visible.
- Where to verify: Order page, audit timeline, scanner sync.
- Evidence: ticket issue ID, attendee ID, invalidation status.
- Failure response: Stop destructive checks.

- Action: Attempt scan after invalidation.
- Expected result: Scanner rejects the ticket.
- Where to verify: Scanner app and scan endpoint.
- Evidence: rejected status only.
- Failure response: Stop; invalid-ticket acceptance blocks wallet work.

## 3. Resend Validation

- Action: From WhatsApp, choose the resend path for the issued ticket.
- Expected result: Flow asks for identity details and does not disclose whether
  a record exists.
- Where to verify: WhatsApp response and conversation state.
- Evidence: conversation ID and state only.
- Failure response: Stop if response leaks identity or record existence.

- Action: Provide matching name/email details.
- Expected result: Backend identity match creates/updates resend challenge and
  sends email OTP.
- Where to verify: challenge state, email adapter/log sink in test-mode.
- Evidence: internal challenge ID and status only.
- Failure response: Stop if no challenge or if PII leaks.

- Action: Submit valid OTP.
- Expected result: Resend challenge reaches verified state and queues ticket
  link worker.
- Where to verify: challenge state, Oban job.
- Evidence: internal challenge ID, queued job ID.
- Failure response: Stop if OTP is logged or public challenge ID leaks.

- Action: Let ticket-link worker send verified resend.
- Expected result: Secure ticket link is sent; challenge is consumed; delivery
  attempt has `delivery_reason = verified_ticket_resend` and internal challenge
  ID only.
- Where to verify: Delivery attempt, challenge state, audit timeline.
- Evidence: delivery attempt ID, internal challenge ID, consumed status.
- Failure response: Stop if delivery does not pair with challenge audit.

- Action: Attempt wrong identity and wrong OTP in sandbox/test-mode.
- Expected result: Both fail generically and do not queue delivery.
- Where to verify: Conversation state, challenge state, Oban queue.
- Evidence: generic failure status only.
- Failure response: Stop if response leaks PII or existence.

Do not record OTP, email address, phone number, public challenge ID, ticket link,
delivery token, token hash, or QR hash.

## 4. Duplicate Webhook And Worker Checks

- Action: Replay the same Paystack sandbox webhook.
- Expected result: Duplicate event is idempotent; no duplicate payment effects.
- Where to verify: Payment event, order status, audit timeline.
- Evidence: payment event ID and duplicate status.
- Failure response: Stop payment launch and block wallet work.

- Action: Re-run payment verification worker for the same order.
- Expected result: Verified payment state remains stable; no duplicate effects.
- Where to verify: payment attempt, order, audit timeline.
- Evidence: payment attempt ID and stable status.
- Failure response: Stop.

- Action: Re-run ticket issuance worker for the same order.
- Expected result: Exactly one ticket issue and attendee per paid unit.
- Where to verify: order page and DB read-only counts.
- Evidence: ticket issue ID and attendee ID.
- Failure response: Stop.

- Action: Re-run ticket-link worker for the same issued ticket if approved in
  sandbox/test-mode.
- Expected result: Outbound dedupe prevents duplicate customer sends unless the
  runbook explicitly exercises verified resend.
- Where to verify: delivery attempts, outbound dedupe, audit timeline.
- Evidence: delivery attempt ID and dedupe status.
- Failure response: Stop on unintended duplicate customer message.

## 5. Ops Dashboard And Audit Timeline

- Action: Open `/dashboard/sales/ops`.
- Expected result: Status counts, failures, manual review, delivery failures,
  scanner visibility, and Oban backlog are visible and redacted.
- Evidence: page status, relevant IDs/statuses only.
- Failure response: Stop if operator cannot observe launch state.

- Action: Open order operations page.
- Expected result: Order, payment, ticket, delivery, scanner, and resend states
  are visible without protected internals.
- Evidence: order ID and visible safe statuses.
- Failure response: Stop if protected values render.

- Action: Open audit timeline for order, payment attempt/event, ticket issue,
  delivery attempt, conversation, and resend challenge where available.
- Expected result: Safe redacted timeline entries load.
- Evidence: entity IDs and timeline loaded status.
- Failure response: Stop if timeline is unavailable or exposes protected data.

## 6. Redaction And Log Spot Check

- Action: Inspect application logs, Sentry if enabled, and collected evidence for
  the smoke correlation IDs.
- Expected result: No protected values appear.
- Failure response: Treat as stop-ship incident and follow incident response.

Check specifically for absence of:

- Phone numbers.
- Emails.
- OTPs.
- Payment links.
- Access codes.
- Ticket links.
- Delivery tokens.
- Delivery token hashes.
- QR hashes.
- Ticket codes.
- Raw provider payloads.
- Raw internal structs.

## 7. Signoff

- Action: Launch owner, operator lead, and developer/admin review evidence.
- Expected result: Every step is pass, not-run with explicit reason, or
  risk-accepted in writing.
- Where to verify: VS-24E evidence template.
- Failure response: Do not start VS-25A wallet work.

VS-25A may start only after VS-24E evidence passes or the launch owner formally
accepts the residual risk.
