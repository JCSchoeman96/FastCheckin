# VS-24E Acceptance Checklist

## Scope Boundary

- [ ] VS-24E is docs-only.
- [ ] No production code changes are included.
- [ ] No config, migration, dependency, router, controller, worker, LiveView,
  asset, Android, scanner, payment, ticket, wallet, refund/revocation, webhook,
  delivery, or test changes are included.
- [ ] Customer delivery is documented as secure ticket link.
- [ ] PDF is documented as dashboard-only/manual staff download.
- [ ] Customer PDF attachment delivery is not claimed or introduced.
- [ ] Apple Wallet and Google Wallet are explicitly out of scope.

## Deliverables

- [ ] Feature pack is added.
- [ ] Coding-agent prompt is added.
- [ ] TOON prompts are added.
- [ ] Acceptance checklist is added.
- [ ] Evidence template is added.
- [ ] `pack.json` is added and follows sibling pack convention.
- [ ] Production checkout and ticket delivery smoke runbook is added.
- [ ] Failure matrix is added.
- [ ] Optional low-value production smoke checklist is added.
- [ ] Runbooks README links the three VS-24E runbooks.

## Smoke Procedure Coverage

- [ ] Environment preflight covers CI, deployed SHA, database, Redis, Oban,
  Paystack, WhatsApp, dashboard auth, and scanner readiness.
- [ ] Sandbox/test-mode happy path starts from WhatsApp checkout.
- [ ] Event WhatsApp sales gate is explicitly enabled for the test event.
- [ ] Disabling the event gate rejects stale WhatsApp checkout confirmation
  without creating a new order/hold and does not invalidate existing truth.
- [ ] Quantity accepts positive multi-digit values within the selected offer
  maximum and renders the dynamic English/Afrikaans range.
- [ ] Correct Paystack payment link is validated without recording the raw URL.
- [ ] Paystack webhook receipt is validated.
- [ ] Server-side Paystack verification is validated.
- [ ] Ticket issuance exactly once is validated.
- [ ] WhatsApp secure ticket link delivery exactly once is validated.
- [ ] Meta provider acceptance is distinguished from `sent`, `delivered`,
  `read`, and `failed` callback evidence.
- [ ] Provider status callbacks are signed, WABA/phone scoped, correlated by
  WAMID, idempotent, and safe for out-of-order delivery.
- [ ] Ambiguous ticket-link transport does not automatically retry or rotate a
  second secure token.
- [ ] Secure ticket page opening is validated.
- [ ] Dashboard/manual PDF download is validated.
- [ ] Scanner sync and valid scan are validated.
- [ ] Mixed Tickera and `fastcheck_sales` attendee coexistence is proven, or a
  blocker is recorded.
- [ ] Resend through WhatsApp + email OTP is validated.
- [ ] Duplicate webhook idempotency is validated.
- [ ] Duplicate worker idempotency is validated.
- [ ] Revoked, refunded, cancelled, archived, expired, and not-scannable paths
  fail closed.
- [ ] Ops dashboard and audit timeline visibility are validated.
- [ ] Log, Sentry, audit, screenshot, and evidence redaction are validated.

## Failure Matrix Coverage

- [ ] Abandoned payment.
- [ ] Duplicate webhook.
- [ ] Provider pending.
- [ ] Amount mismatch.
- [ ] Currency mismatch.
- [ ] Reference mismatch.
- [ ] Expired checkout.
- [ ] Duplicate ticket issuer run.
- [ ] WhatsApp send failure.
- [ ] Secure token invalid or expired.
- [ ] Revoked ticket.
- [ ] Refunded or cancelled order.
- [ ] Archived or not-scannable ticket.
- [ ] Wrong resend identity.
- [ ] Wrong OTP.
- [ ] OTP lock or rate limit.
- [ ] Duplicate resend.
- [ ] Dashboard PDF unavailable.
- [ ] Scanner accepts invalid ticket.

## Evidence Safety

- [ ] Evidence template allows only redacted IDs, statuses, timestamps, and
  operator notes.
- [ ] Raw payment URLs are forbidden.
- [ ] Paystack access codes are forbidden.
- [ ] Ticket links are forbidden.
- [ ] Delivery tokens and token hashes are forbidden.
- [ ] QR hashes and ticket code screenshots are forbidden.
- [ ] OTPs are forbidden.
- [ ] Phone numbers and emails are forbidden.
- [ ] Raw provider payloads are forbidden.
- [ ] Screenshots containing protected values are forbidden.

## Verification Commands

- [ ] `mix format --check-formatted` is listed.
- [ ] `mix compile --warnings-as-errors` is listed.
- [ ] Relevant VS-22/E2E, Paystack, WhatsApp, issuance, secure ticket, PDF,
  resend, scanner, Sobelow, and `mix precommit` commands are listed.
- [ ] Existing tests only are required unless explicitly instructed otherwise.

## Go/No-Go

- [ ] VS-25A Apple Wallet and Google Wallet are blocked until VS-24E evidence
  passes or risk is formally accepted.
- [ ] Stop conditions include payment mismatch, duplicate issuance, invalid
  scanner acceptance, resend bypass, PDF attachment assumption, and protected
  value leakage.
- [ ] Optional low-value production smoke requires launch owner/operator signoff.
- [ ] Any smoke failure must be documented and the smoke must stop; bug fixes are
  out of scope for VS-24E.
