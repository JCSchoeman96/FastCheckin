# VS-24E Optional Low-Value Production Smoke

Run this only after the VS-24E sandbox/test-mode smoke has passed and the launch
owner explicitly approves a live low-value payment.

This checklist validates the live provider path with a hidden/internal event and
a low-value ticket. It is not a load test and must not simulate flash-sale
traffic.

## Required Signoff Before Starting

- [ ] Sandbox/test-mode VS-24E smoke passed.
- [ ] Launch owner approved low-value production smoke.
- [ ] Operator lead is present.
- [ ] Developer/admin observer is present.
- [ ] Paystack account owner or incident contact is reachable.
- [ ] Meta/WhatsApp account owner or incident contact is reachable.
- [ ] Refund/revocation policy for the test ticket is approved.
- [ ] Hidden/internal event and low-value offer are confirmed.
- [ ] Evidence template is ready and contains no protected values.

## Production Constraints

- Use one hidden/internal event.
- Use one low-value ticket.
- Use one approved operator/customer test contact.
- Use one approved scanner device/session.
- Do not run broad production queries.
- Do not paste raw payment links, ticket links, tokens, OTPs, phone numbers,
  emails, or provider payloads anywhere.
- Do not refund or revoke unless the launch owner approved that cleanup path.
- Do not test destructive revoked/refunded scan behavior in production unless
  explicitly approved.

## Stop Immediately If

- Payment mode or event is ambiguous.
- Payment amount, currency, or reference is wrong.
- Webhook receipt alone appears to issue tickets.
- Server-side verification fails or mismatches.
- More than one ticket issue or attendee is created for one paid unit.
- Customer receives a PDF attachment.
- Secure ticket link, payment URL, token, hash, OTP, phone, email, or provider
  payload leaks.
- Scanner accepts a ticket that should be invalid.
- Resend bypasses identity match or email OTP.
- Ops dashboard or audit timeline cannot show the run safely.

## Checklist

### 1. Live Environment Preflight

- [ ] Deployed commit SHA matches approved release.
- [ ] CI is green for the release candidate.
- [ ] Database migrations are applied.
- [ ] Redis health is confirmed.
- [ ] Oban queues are running.
- [ ] Paystack live mode is deliberate.
- [ ] Meta/WhatsApp live mode is deliberate; `META_WHATSAPP_SANDBOX_MODE` is
  explicit and configured WABA/phone scope is confirmed.
- [ ] Dashboard auth works for assigned operator.
- [ ] Scanner/mobile auth works for hidden/internal event.

### 2. Hidden Event And Offer

- [ ] Hidden/internal event is active only for the approved smoke.
- [ ] Low-value offer amount is correct.
- [ ] Inventory availability matches the approved test quantity.
- [ ] Event/offer labels are recorded without PII.

### 3. Live Checkout And Payment

- [ ] Approved test customer starts WhatsApp checkout.
- [ ] Event and offer selection complete.
- [ ] Buyer details and confirmation complete.
- [ ] Payment link is sent once.
- [ ] Payment-link DeliveryAttempt records provider acceptance separately from
  actual Meta `sent`/`delivered`/`read` evidence.
- [ ] Paystack page shows expected live mode, amount, currency, and redacted
  reference.
- [ ] Payment is completed.
- [ ] Webhook reaches app.
- [ ] Server-side verification succeeds.

Do not record the raw payment URL or access code.

### 4. Ticket And Delivery

- [ ] Order reaches verified paid / fulfillment state.
- [ ] Exactly one ticket issue is created for the paid unit.
- [ ] Exactly one attendee is created for the paid unit.
- [ ] WhatsApp secure ticket link is sent once.
- [ ] Signed Meta status callbacks reconcile the tracked WAMID idempotently and
  do not mutate payment, ticket, inventory, or scanner authority.
- [ ] An ambiguous ticket-link timeout/connection loss is manual-review/no-auto-
  retry and does not rotate another secure token.
- [ ] Secure ticket page opens.

Do not record the ticket link, delivery token, token hash, QR hash, or ticket
code.

### 5. Dashboard PDF

- [ ] Assigned dashboard operator opens the order page.
- [ ] Dashboard/manual PDF download returns `application/pdf`.
- [ ] Response is private/no-store/noindex where applicable.
- [ ] PDF is not sent to the customer.
- [ ] No delivery attempt is created by the PDF download.
- [ ] PDF is not stored as part of the smoke.

### 6. Scanner

- [ ] Approved scanner sync sees the attendee.
- [ ] Valid scan succeeds according to current scanner rules.
- [ ] Scan result is visible in safe operator surfaces.

### 6A. Event gate, quantity, and source checks

- [ ] Event-level `whatsapp_sales_enabled` is enabled deliberately.
- [ ] Disabling the event gate rejects stale WhatsApp checkout without a new
  order/hold and leaves existing paid/in-flight recovery intact.
- [ ] Multi-digit quantity and dynamic AF/EN maximum prompt are verified.
- [ ] Mixed Tickera and `fastcheck_sales` source proof is complete or explicitly
  marked not applicable with reason.

Do not test invalid destructive scan paths in production unless explicitly
approved.

### 7. Resend

- [ ] Approved resend path starts from WhatsApp.
- [ ] Identity match step completes.
- [ ] Email OTP is sent and verified.
- [ ] Verified resend queues secure ticket link delivery.
- [ ] Resend delivery attempt has `delivery_reason = verified_ticket_resend`.
- [ ] Challenge is consumed.

Do not record OTP, email, phone, ticket link, token, hash, or public challenge
ID.

### 8. Ops And Redaction

- [ ] `/dashboard/sales/ops` shows safe statuses.
- [ ] Order page shows safe order/payment/ticket/delivery/scanner state.
- [ ] Audit timeline shows safe redacted entries.
- [ ] Logs/Sentry/evidence spot check contains no protected values.

## Cleanup

Choose only the cleanup path approved before starting:

- [ ] Leave low-value ticket as accepted live smoke record.
- [ ] Revoke ticket with approved reason.
- [ ] Refund/cancel through approved operator process.
- [ ] No cleanup action taken because owner deferred it.

Record only IDs, statuses, timestamps, and operator initials.

## Signoff

VS-25A wallet work remains blocked until the low-value production smoke is
passed, skipped with explicit risk acceptance, or declared not required by the
launch owner after sandbox/test-mode evidence passes.
