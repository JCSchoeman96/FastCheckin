# VS-24E Redacted Evidence Template

Use this template for sandbox/test-mode smoke evidence and optional low-value
production smoke evidence.

Do not paste protected values into this file, PR descriptions, issue comments,
screenshots, chat, logs, or audit notes.

## Run Metadata

| Field | Value |
|---|---|
| Evidence pack version | VS-24E |
| Environment | `[sandbox/test-mode/staging/production-low-value]` |
| App commit SHA | `[commit-sha]` |
| Deployed release label | `[release-label]` |
| Date/time window | `[ISO8601 start]` to `[ISO8601 end]` |
| Timezone | `[timezone]` |
| Launch owner | `[role/name or initials]` |
| Operator | `[role/name or initials]` |
| Developer/admin observer | `[role/name or initials]` |
| Event label | `[internal event label only]` |
| Ticket offer label | `[internal offer label only]` |

## Allowed Evidence Identifiers

Use internal IDs and redacted suffixes only.

| Evidence Item | Value | Status | Notes |
|---|---|---|---|
| Checkout session ID | `[id]` | `[pass/fail]` | `[redacted note]` |
| Order ID | `[id]` | `[pass/fail]` | `[redacted note]` |
| Redacted order reference suffix | `...[suffix]` | `[pass/fail]` | `[redacted note]` |
| Payment attempt ID | `[id]` | `[pass/fail]` | `[redacted note]` |
| Payment event ID | `[id]` | `[pass/fail]` | `[redacted note]` |
| Verify payment Oban job ID | `[id]` | `[pass/fail]` | `[redacted note]` |
| Ticket issue ID | `[id]` | `[pass/fail]` | `[redacted note]` |
| Attendee ID | `[id]` | `[pass/fail]` | `[redacted note]` |
| Ticket link delivery attempt ID | `[id]` | `[pass/fail]` | `[redacted note]` |
| Provider status evidence ID(s) | `[id(s)]` | `[pass/fail]` | Status/timestamp and WAMID hash only; no raw WAMID or payload |
| Ticket link Oban job ID | `[id]` | `[pass/fail]` | `[redacted note]` |
| Scanner sync result ID/correlation | `[id]` | `[pass/fail]` | `[redacted note]` |
| Scan upload result ID/correlation | `[id]` | `[pass/fail]` | `[redacted note]` |
| Dashboard PDF request correlation | `[id]` | `[pass/fail]` | `[redacted note]` |
| Resend challenge internal ID | `[id]` | `[pass/fail]` | Do not include public challenge ID |
| Resend delivery attempt ID | `[id]` | `[pass/fail]` | `[redacted note]` |
| Audit timeline correlation | `[id]` | `[pass/fail]` | `[redacted note]` |

## Protected Values Forbidden In Evidence

Do not record:

- Raw Paystack payment URL.
- Paystack access code.
- Full Paystack provider reference if it can be used externally.
- Raw webhook payload.
- Ticket link.
- Delivery token.
- Delivery token hash.
- QR hash.
- Ticket code or scanner payload in screenshots.
- OTP.
- Email address.
- Phone number.
- WhatsApp `wa_id`.
- Provider message payload.
- Raw internal structs.
- Screenshots containing any protected value above.

## Automated Verification Evidence

| Command | Result | Evidence Location |
|---|---|---|
| `mix format --check-formatted` | `[pass/fail/not-run]` | `[CI/local note]` |
| `mix compile --warnings-as-errors` | `[pass/fail/not-run]` | `[CI/local note]` |
| VS-22/E2E focused tests | `[pass/fail/not-run]` | `[CI/local note]` |
| Paystack verification tests | `[pass/fail/not-run]` | `[CI/local note]` |
| WhatsApp payment/ticket/resend tests | `[pass/fail/not-run]` | `[CI/local note]` |
| Secure ticket tests | `[pass/fail/not-run]` | `[CI/local note]` |
| Dashboard PDF controller tests | `[pass/fail/not-run]` | `[CI/local note]` |
| Scanner/revocation visibility tests | `[pass/fail/not-run]` | `[CI/local note]` |
| `mix sobelow --exit --compact` | `[pass/fail/not-run]` | `[CI/local note]` |
| `mix precommit` | `[pass/fail/not-run]` | `[CI/local note]` |
| `mix ci` | `[pass/fail/not-run]` | `[CI/local note]` |
| `git diff --check` | `[pass/fail/not-run]` | `[CI/local note]` |

## Smoke Evidence Checklist

- [ ] Runtime environment and secrets preflight passed without printing secrets.
- [ ] Database migration/pooling preflight passed.
- [ ] Redis availability/holds/session/dedupe preflight passed.
- [ ] Oban queue preflight passed.
- [ ] WhatsApp inbound checkout started.
- [ ] Event and ticket offer selected.
- [ ] Quantity and buyer details collected.
- [ ] Payment link sent once.
- [ ] Payment-link DeliveryAttempt shows provider acceptance separately from
  actual Meta status.
- [ ] Paystack payment completed in intended mode.
- [ ] Paystack webhook reached app.
- [ ] Server-side verification succeeded.
- [ ] Order reached verified paid / fulfillment state.
- [ ] Ticket issued exactly once.
- [ ] Attendee created exactly once per paid unit.
- [ ] Secure ticket link sent once.
- [ ] Ticket-link DeliveryAttempt status is reconciled only from signed,
  configured-scope Meta callbacks.
- [ ] Unknown/out-of-scope provider callbacks are safely acknowledged/ignored.
- [ ] Ambiguous ticket-link transport is manual-review/no-auto-retry and does
  not rotate a second token.
- [ ] Secure ticket page opened.
- [ ] Dashboard/manual PDF download worked.
- [ ] Scanner sync saw attendee.
- [ ] Mixed Tickera and `fastcheck_sales` attendee proof is recorded with source
  and eligibility labels only.
- [ ] Valid scan succeeded.
- [ ] Duplicate webhook did not duplicate effects.
- [ ] Duplicate worker run did not duplicate ticket or attendee.
- [ ] Revoked/refunded/not-scannable paths failed closed.
- [ ] Verified resend required identity match and email OTP.
- [ ] Wrong identity failed generically.
- [ ] Wrong OTP failed generically.
- [ ] Ops dashboard showed safe statuses.
- [ ] Audit timeline showed safe redacted entries.
- [ ] Logs/Sentry/evidence spot check found no protected values.

## Signoff

| Role | Name/Initials | Decision | Date/Time |
|---|---|---|---|
| Launch owner | `[redacted]` | `[go/no-go/risk-accepted]` | `[ISO8601]` |
| Operator lead | `[redacted]` | `[go/no-go/risk-accepted]` | `[ISO8601]` |
| Developer/admin | `[redacted]` | `[go/no-go/risk-accepted]` | `[ISO8601]` |

## Notes

Record only redacted operational observations. If a protected value appears in
evidence, stop the smoke and follow the incident process.
