# Go/No-Go Checklist

## Code And CI

- [ ] Current release candidate is based on current `main`.
- [ ] CI is green for the release candidate.
- [ ] `mix format --check-formatted` passes.
- [ ] `mix compile --warnings-as-errors` passes.
- [ ] VS-22 E2E suite is green or the release owner accepts documented risk.
- [ ] No production code, config, migration, dependency, router, worker, or test
  changes are included in this docs-only PR.

## Environment And Secrets

- [ ] `SECRET_KEY_BASE` is present and not logged.
- [ ] `ENCRYPTION_KEY` is present and not logged.
- [ ] `SALES_HOLD_TOKEN_PEPPER` is present and not logged.
- [ ] `TICKET_TOKEN_PEPPER` is present and not logged.
- [ ] `DASHBOARD_USERNAME` and `DASHBOARD_PASSWORD` authenticate the assigned
  operator.
- [ ] Paystack secret variables are present and not logged.
- [ ] Meta/WhatsApp secret variables are present and not logged.
- [ ] `MOBILE_JWT_SECRET` is present and not logged.
- [ ] Sentry is configured if used, and sensitive filtering is enabled.

## Database

- [ ] `DATABASE_URL` points at the intended launch database.
- [ ] `DATABASE_POOLING_MODE` is correct for deployment.
- [ ] `DB_PREPARE_MODE` is compatible with pooling.
- [ ] Migrations are applied.
- [ ] No pending migrations remain.
- [ ] Sales, attendee, and invalidation tables are queryable.
- [ ] No stale sandbox data exists in the launch event.

## Redis

- [ ] `REDIS_URL` points at the intended Redis instance.
- [ ] Redis is reachable from the app.
- [ ] Launch offer inventory availability matches approved quantity.
- [ ] No stale hold keys exist for launch event.
- [ ] Redis recovery procedure is available to operators.

## Oban

- [ ] Oban is running.
- [ ] Paystack webhook, verification, issuance, checkout expiry, and WhatsApp
  send workers are processing.
- [ ] Oban retry backlog is visible in `/dashboard/sales/ops`.
- [ ] No unexpected retry backlog exists before launch.

## Paystack

- [ ] `PAYSTACK_ENABLED` and `PAYSTACK_ENVIRONMENT` match launch mode.
- [ ] A sandbox Paystack transaction initializes and produces a provider
  reference during rehearsal.
- [ ] Paystack webhook reaches `POST /api/sales/paystack/webhook`.
- [ ] Webhook signature verification succeeds.
- [ ] Server-side verification succeeds.
- [ ] Duplicate Paystack webhook does not create duplicate payment effects.
- [ ] Failed, pending, amount mismatch, currency mismatch, and reference mismatch
  do not issue tickets.
- [ ] Webhook receipt alone does not issue tickets.

## WhatsApp/Meta

- [ ] `META_WHATSAPP_ENABLED` is set deliberately.
- [ ] Inbound webhook verification succeeds.
- [ ] Test inbound message creates or resumes a conversation.
- [ ] Outbound text send succeeds inside 24-hour window.
- [ ] Approved template send succeeds outside 24-hour window.
- [ ] Duplicate inbound messages are deduped.
- [ ] Duplicate outbound jobs do not duplicate sends.
- [ ] Missing template routes to fallback/manual review.

## Sales Event, Offer, And Inventory

- [ ] Active launch event exists.
- [ ] Active WhatsApp offer exists.
- [ ] Admin-assisted offer path is configured if used.
- [ ] Internal pilot path is configured if used.
- [ ] Public web checkout remains deferred.
- [ ] Offer quantity matches approved launch quantity.
- [ ] Checkout reserves Redis inventory.

## Ticket Issuance

- [ ] Verified paid order triggers `IssueTicketsWorker`.
- [ ] One ticket issue is created per purchased unit.
- [ ] One attendee is created per purchased unit.
- [ ] Duplicate issuer run does not duplicate tickets or attendees.
- [ ] Ticket codes, QR material, delivery tokens, and hashes are not logged.

## Secure Ticket Page

- [ ] Valid secure ticket link opens through `GET /t/:token`.
- [ ] Expired token does not expose a valid ticket.
- [ ] Revoked ticket link does not expose a valid scannable ticket.
- [ ] Internal token hashes are not rendered.

## Scanner/Mobile

- [ ] Mobile JWT settings match scanner expectations.
- [ ] Mobile sync sees issued attendees.
- [ ] Valid issued ticket scans successfully.
- [ ] Revoked ticket is rejected by the mobile scan endpoint.
- [ ] Invalidation event is created after revocation.
- [ ] Event sync version changes after scanner-visible revocation.
- [ ] Mobile/scanner runtime tuning variables are set deliberately.

## Admin And Manual Review

- [ ] Manual review operator is assigned.
- [ ] Refund/revocation operator is assigned.
- [ ] `/dashboard/sales/reviews` is reachable.
- [ ] Admin-assisted checkout uses shared Sales core.
- [ ] Internal pilot checkout uses shared Sales core.
- [ ] Destructive admin action requires reason.
- [ ] Destructive admin action is audited.

## Ops Dashboard And Audit

- [ ] `/dashboard/sales/ops` loads under dashboard auth.
- [ ] Orders by status are visible.
- [ ] Payment failures/mismatches are visible without raw payloads.
- [ ] Manual review count is visible.
- [ ] Delivery failure/fallback count is visible.
- [ ] Scanner visibility pending count is visible.
- [ ] Oban retry backlog is visible.
- [ ] `/dashboard/sales/audit/:entity_type/:entity_id` loads redacted timeline.

## Monitoring And Logging

- [ ] App logs do not include customer phone numbers, emails, payment links,
  ticket links, access codes, raw provider payloads, or token hashes.
- [ ] Sentry filtering is active if Sentry is enabled.
- [ ] Paystack dashboard access is available to incident owner.
- [ ] Meta dashboard access is available to WhatsApp incident owner.

## Incident Contacts

- [ ] Launch owner is assigned.
- [ ] Operator lead is assigned.
- [ ] Developer/admin escalation contact is assigned.
- [ ] Paystack account owner is assigned.
- [ ] Meta/WhatsApp account owner is assigned.
- [ ] Refund/revocation operator is assigned.

## Rollback/Pause-Sales Readiness

- [ ] Pause-sales procedure is reviewed.
- [ ] Operator knows what must continue running during pause.
- [ ] Operator knows what must not be manually edited.
- [ ] Resume criteria are reviewed.

## Final Signoff

- [ ] Sandbox dress rehearsal passed.
- [ ] First live transaction operator is assigned.
- [ ] Manual review coverage is active for launch window.
- [ ] Incident response owner is active for launch window.
- [ ] Launch owner signs go.

