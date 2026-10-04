# Post-Launch Monitoring

## Approved global worker monitoring

Use `/dashboard/system/workers` as the approved, read-only global queue source.
Access uses the server-owned global monitoring username allowlist. The page is
not Event-scoped; `/dashboard/sales/ops` remains limited to Event-attributable
Sales metrics.

P1-F query-plan evidence and runbook rehearsal are complete, and the P1-F
implementation/evidence blocker is cleared. P1-E remains independent and open.
These results do not clear every production launch gate. Verify live monitoring
and all other launch checks for the actual environment. Do not use ad-hoc SQL as
a workaround.

## First Hour

Every 10 minutes for the first hour:

- Open `/dashboard/sales/ops`.
- Open `/dashboard/system/workers`.
- Confirm monitoring status is `Current`, snapshot age is at most 30 seconds,
  and distribution is healthy. Escalate if status is `Stale`, `Unavailable`, or
  the page reports a degraded shared mirror.
- Review all configured queues and the single `Unexpected queues` aggregate.
  Age fields are meaningful only when their matching state count is non-zero.
- Treat the Prometheus gauges as replicated global values. Query them with
  `max without(instance)`. Never sum these gauges across instances.
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
- Use Ops Dashboard for Event-attributable Sales failure counts.
- Use the worker page for global queue pressure. It has no retry, pause, delete,
  or other mutation controls.
- Pause new sales if incident thresholds are met.

## End-Of-Day Signoff

- Launch owner reviews successful transaction count.
- Operator lead reviews manual review and delivery failure backlog.
- Developer/admin reviews incidents and logs. Operators use
  `/dashboard/system/workers` for global worker status according to the
  rehearsed procedure, and verify current health for the active environment.
- Refund/revocation operator reviews all destructive actions.
- Decision is recorded: continue, continue with mitigations, or pause sales.

P1F_QUERY_PLAN_EVIDENCE=PASS
P1F_RUNBOOK_REHEARSAL=PASS
P1F_GLOBAL_OBAN_BLOCKER=CLEARED
P1E_INGRESS_BLOCKER=OPEN
