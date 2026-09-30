# Post-Launch Monitoring

## Pre-Launch Blocker

The production source and procedure for global Oban backlog monitoring remain
unresolved under P1-F. Production launch is NO-GO until an approved source
exists and staff have rehearsed its procedure. `/dashboard/sales/ops` is
Event-scoped and is not an approved substitute. Do not use ad-hoc SQL as a
workaround.

## First Hour

Every 10 minutes for the first hour:

- Open `/dashboard/sales/ops`.
- Check orders by status for unexpected `manual_review`, `expired`, or stalled
  `awaiting_payment` growth.
- Check payment failures and mismatches.
- Check manual review queue count and assignment.
- Check delivery failures and fallback-required count.
- Check scanner visibility pending count.
- Open Audit Timeline for at least one completed order and confirm safe redacted
  order, payment, ticket, delivery, and conversation entries.
- Confirm Paystack webhooks are arriving.
- Confirm Paystack verification is completing.
- Confirm WhatsApp inbound messages are arriving.
- Confirm WhatsApp outbound sends are succeeding.
- Confirm mobile sync sees newly issued attendees.
- Confirm scanner accepts valid tickets.

Escalate immediately if:

- Verified payments are not issuing tickets.
- Ticket links are not being delivered after tickets issue.
- Scanner rejects a valid issued ticket.
- Scanner accepts a revoked/refunded ticket.
- Manual review backlog grows faster than operator capacity.
- Logs expose phone numbers, emails, payment links, ticket links, raw payloads,
  access codes, or token hashes.

## First Day

At least hourly during the first day:

- Review `/dashboard/sales/ops` by launch event and source channel.
- Review payment failure and mismatch patterns.
- Review manual review resolution time.
- Review delivery attempts for failed, fallback-required, and manual-review
  status.
- Review scanner visibility pending count.
- Review Audit Timeline for a sample of successful orders.
- Review Audit Timeline for each incident or manual review order.
- Confirm Paystack dashboard totals align with local verified payment counts.
- Confirm Meta dashboard send failures align with local delivery attempts.
- Confirm refund/revocation actions have reasons and scanner denial evidence.

## Operator Actions

- Keep support responses inside approved channels.
- Do not paste payment links, ticket links, tokens, access codes, phone numbers,
  or email addresses into public incident notes.
- Use Audit Timeline for state history instead of raw DB dumps.
- Use Ops Dashboard for Event-attributable Sales failure counts. It does not
  report global worker queue pressure. P1-F must provide that monitoring before
  production launch.
- Pause new sales if incident thresholds are met.

## End-Of-Day Signoff

- Launch owner reviews successful transaction count.
- Operator lead reviews manual review and delivery failure backlog.
- Developer/admin reviews incidents and logs. Global retry backlog monitoring
  remains blocked by P1-F until an approved source and procedure exist.
- Refund/revocation operator reviews all destructive actions.
- Decision is recorded: continue, continue with mitigations, or pause sales.
