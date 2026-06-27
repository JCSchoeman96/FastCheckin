# Incident Response

Use this guide for launch incidents. Keep Paystack webhook ingestion, payment
verification, issuance recovery, expiry cleanup, manual review, revocation
safety, and scanner/mobile sync running unless a developer/admin explicitly
directs otherwise.

## Paystack webhook not arriving

- Incident name: Paystack webhook not arriving.
- Symptoms: Paystack shows payment activity but no new local payment event.
- Severity: High.
- First checks: Confirm `PAYSTACK_WEBHOOK_URL`, app deploy health, and provider
  retry status.
- What to inspect in Ops Dashboard: Payment failures, awaiting payment growth,
  Oban backlog.
- What to inspect in Audit Timeline: Order and payment attempt entries.
- Safe immediate action: Pause new checkouts if payments cannot be observed.
- Unsafe actions to avoid: Do not manually mark payment verified.
- Recovery procedure: Fix webhook URL/network issue, allow provider retry, then
  run approved verification path.
- Verification after recovery: New webhook stores payment event and verification
  completes.
- Escalation trigger: Any paid customer remains unverified after provider retry.

## Paystack webhook signature failures

- Incident name: Paystack webhook signature failures.
- Symptoms: Webhook requests arrive but are rejected.
- Severity: High.
- First checks: Verify secret/config alignment and recent credential changes.
- What to inspect in Ops Dashboard: Payment failure pressure and manual review.
- What to inspect in Audit Timeline: Payment event absence or rejected path.
- Safe immediate action: Pause new checkouts while signature config is corrected.
- Unsafe actions to avoid: Do not disable signature verification for launch.
- Recovery procedure: Restore correct secret, replay or wait for provider retry.
- Verification after recovery: Signed webhook stores payment event once.
- Escalation trigger: Signature failures continue after credential correction.

## Paystack verification failing or timing out

- Incident name: Paystack verification failing or timing out.
- Symptoms: Payment events exist but attempts do not reach verified success.
- Severity: High.
- First checks: Paystack API health, `PAYSTACK_TIMEOUT_MS`, network egress.
- What to inspect in Ops Dashboard: Retry backlog and payment failures.
- What to inspect in Audit Timeline: Payment attempt verification entries.
- Safe immediate action: Keep retries running; pause new checkouts if backlog
  grows.
- Unsafe actions to avoid: Do not issue tickets from webhook alone.
- Recovery procedure: Restore API connectivity, allow retry, manually assign
  unresolved orders to review.
- Verification after recovery: Verification succeeds and issuance follows.
- Escalation trigger: Verified provider payments remain unresolved.

## Duplicate Paystack webhook storm

- Incident name: Duplicate Paystack webhook storm.
- Symptoms: Many repeat webhook deliveries for the same provider event.
- Severity: Medium to high.
- First checks: Redis dedupe health and provider retry reason.
- What to inspect in Ops Dashboard: Payment event pressure and Oban backlog.
- What to inspect in Audit Timeline: Payment event and order idempotency.
- Safe immediate action: Keep dedupe and workers running; pause new checkouts if
  worker backlog threatens recovery.
- Unsafe actions to avoid: Do not delete duplicate evidence.
- Recovery procedure: Resolve provider retry cause and let idempotency collapse
  duplicates.
- Verification after recovery: One payment effect and one ticket set per order.
- Escalation trigger: Duplicate effects appear on an order.

## Payment verified but ticket not issued

- Incident name: Payment verified but ticket not issued.
- Symptoms: Payment attempt verified success, order not ticket issued.
- Severity: Critical.
- First checks: `IssueTicketsWorker`, Oban backlog, order state, inventory state.
- What to inspect in Ops Dashboard: Ticket issuance failures and retry backlog.
- What to inspect in Audit Timeline: Order, payment attempt, and ticket issue.
- Safe immediate action: Keep issuance recovery running; pause new checkouts if
  repeated.
- Unsafe actions to avoid: Do not manually create ticket rows.
- Recovery procedure: Retry approved issuer path or escalate to developer/admin.
- Verification after recovery: Correct ticket and attendee count exists.
- Escalation trigger: More than one verified order is stuck.

## Ticket issued but secure ticket link not delivered

- Incident name: Ticket issued but secure ticket link not delivered.
- Symptoms: Order is ticket issued; customer has no ticket message.
- Severity: High.
- First checks: `SendWhatsAppTicketLinkWorker`, delivery attempts, Meta response.
- What to inspect in Ops Dashboard: Delivery failure and fallback counts.
- What to inspect in Audit Timeline: Ticket issue and delivery attempt.
- Safe immediate action: Assign manual review and resend only through approved
  worker path.
- Unsafe actions to avoid: Do not paste ticket link into public notes.
- Recovery procedure: Fix provider/template issue and run approved delivery path.
- Verification after recovery: Delivery attempt sent and secure page opens.
- Escalation trigger: Multiple ticket-issued orders lack delivery.

## WhatsApp inbound webhook failing

- Incident name: WhatsApp inbound webhook failing.
- Symptoms: Customer messages do not create or update conversations.
- Severity: High.
- First checks: Webhook URL, verify token, app secret, rate limits, logs.
- What to inspect in Ops Dashboard: Conversation/manual review impact.
- What to inspect in Audit Timeline: Conversation absence or last known state.
- Safe immediate action: Pause WhatsApp entrypoint; keep payment recovery paths.
- Unsafe actions to avoid: Do not create ad hoc conversations in DB.
- Recovery procedure: Restore webhook config and test inbound message.
- Verification after recovery: Inbound message persists and queues processing.
- Escalation trigger: Inbound remains down during live customer traffic.

## WhatsApp outbound sends failing

- Incident name: WhatsApp outbound sends failing.
- Symptoms: Payment or ticket messages are not delivered.
- Severity: High.
- First checks: Meta auth, rate limits, provider status, outbound worker backlog.
- What to inspect in Ops Dashboard: Delivery failure/fallback counts.
- What to inspect in Audit Timeline: Delivery attempt entries.
- Safe immediate action: Assign manual review; pause new WhatsApp checkouts if
  needed.
- Unsafe actions to avoid: Do not bypass approved workers.
- Recovery procedure: Restore Meta send path and retry approved jobs.
- Verification after recovery: Delivery attempts reach sent.
- Escalation trigger: Paid orders cannot receive ticket links.

## WhatsApp template unavailable or rejected

- Incident name: WhatsApp template unavailable or rejected.
- Symptoms: Outside-window ticket sends move to fallback/manual review.
- Severity: High.
- First checks: Template approval, language, local catalog, Meta validation.
- What to inspect in Ops Dashboard: Fallback-required delivery count.
- What to inspect in Audit Timeline: Delivery attempt failure reason.
- Safe immediate action: Keep ticket issuance running and assign manual review.
- Unsafe actions to avoid: Do not send unapproved free-form outside the window.
- Recovery procedure: Restore approved template or wait for approval.
- Verification after recovery: Outside-window send uses approved template.
- Escalation trigger: Outside-window deliveries cannot be completed.

## Redis unavailable

- Incident name: Redis unavailable.
- Symptoms: Inventory, dedupe, session, or cache operations fail.
- Severity: Critical.
- First checks: Redis health, `REDIS_URL`, network, app connection errors.
- What to inspect in Ops Dashboard: Checkout failures, webhook storm, backlog.
- What to inspect in Audit Timeline: Orders stuck before payment or delivery.
- Safe immediate action: Pause new checkouts and WhatsApp entrypoints.
- Unsafe actions to avoid: Do not manually reconstruct inventory keys.
- Recovery procedure: Restore Redis, then reconcile inventory and sessions.
- Verification after recovery: New checkout hold, dedupe, and session operations
  succeed.
- Escalation trigger: Redis cannot be restored quickly.

## Checkout expiry backlog

- Incident name: Checkout expiry backlog.
- Symptoms: Expired sessions remain reserved or awaiting payment.
- Severity: Medium.
- First checks: Checkout expiry worker and Oban backlog.
- What to inspect in Ops Dashboard: Expired/awaiting counts and worker backlog.
- What to inspect in Audit Timeline: Checkout session state transitions.
- Safe immediate action: Keep expiry cleanup running; pause new checkouts if
  inventory is blocked.
- Unsafe actions to avoid: Do not manually delete holds without recovery process.
- Recovery procedure: Restore worker processing and reconcile held inventory.
- Verification after recovery: Expired holds release once.
- Escalation trigger: Launch offer availability is blocked by stale holds.

## Manual review backlog

- Incident name: Manual review backlog.
- Symptoms: Manual review count grows beyond assigned operator capacity.
- Severity: Medium to high.
- First checks: Cause mix: payment mismatch, expiry, delivery fallback, provider
  failures.
- What to inspect in Ops Dashboard: Manual review and recent failures.
- What to inspect in Audit Timeline: Sample order/payment/delivery timelines.
- Safe immediate action: Add operator coverage or pause new sales.
- Unsafe actions to avoid: Do not bulk-resolve without inspecting evidence.
- Recovery procedure: Triage by paid customer impact first.
- Verification after recovery: Backlog trends down and no paid orders are stuck.
- Escalation trigger: Backlog grows for two monitoring intervals.

## Scanner rejects valid ticket

- Incident name: Scanner rejects valid ticket.
- Symptoms: Issued, active customer ticket is denied.
- Severity: Critical.
- First checks: Attendee row, ticket issue status, mobile sync, event scope.
- What to inspect in Ops Dashboard: Scanner visibility pending count.
- What to inspect in Audit Timeline: Ticket issue and invalidation timeline.
- Safe immediate action: Pause scanning lane for affected event if repeated.
- Unsafe actions to avoid: Do not manually mark attendee scannable.
- Recovery procedure: Refresh mobile sync and escalate state mismatch.
- Verification after recovery: Valid issued ticket scans successfully.
- Escalation trigger: More than one valid ticket is rejected.

## Scanner accepts should-be-revoked ticket

- Incident name: Scanner accepts should-be-revoked ticket.
- Symptoms: Revoked/refunded ticket scans successfully.
- Severity: Critical.
- First checks: Revocation state, attendee invalidation event, event sync version,
  mobile sync freshness.
- What to inspect in Ops Dashboard: Scanner visibility pending count.
- What to inspect in Audit Timeline: Revocation and attendee invalidation.
- Safe immediate action: Pause affected scanner lane and refresh devices.
- Unsafe actions to avoid: Do not manually edit attendee scanner state.
- Recovery procedure: Force device sync through approved path and escalate.
- Verification after recovery: Revoked ticket is denied.
- Escalation trigger: Any revoked paid ticket is accepted.

## Customer paid after checkout expired

- Incident name: Customer paid after checkout expired.
- Symptoms: Late verified payment for expired checkout.
- Severity: High.
- First checks: Checkout/session state, payment attempt, inventory availability.
- What to inspect in Ops Dashboard: Manual review and payment failures.
- What to inspect in Audit Timeline: Checkout expiry and payment verification.
- Safe immediate action: Assign manual review.
- Unsafe actions to avoid: Do not issue ticket without approved recovery path.
- Recovery procedure: Follow payment-after-expiry policy and support customer.
- Verification after recovery: Order reaches approved final state and audit is
  complete.
- Escalation trigger: Multiple late payments occur.

## DeliveryAttempt fallback/manual-review spike

- Incident name: DeliveryAttempt fallback/manual-review spike.
- Symptoms: Many deliveries enter failed, fallback-required, or manual review.
- Severity: High.
- First checks: Meta auth, template approval, rate limits, worker backlog.
- What to inspect in Ops Dashboard: Delivery failure/fallback counts.
- What to inspect in Audit Timeline: Delivery attempt sample timelines.
- Safe immediate action: Assign manual review and pause new WhatsApp sales if
  ticket delivery cannot recover.
- Unsafe actions to avoid: Do not bypass delivery workers.
- Recovery procedure: Restore provider/template path and retry approved jobs.
- Verification after recovery: New delivery attempts reach sent.
- Escalation trigger: Paid customers cannot receive secure ticket links.

## Oban queue backlog

- Incident name: Oban queue backlog.
- Symptoms: Worker retry or available backlog grows.
- Severity: High if payment, issuance, expiry, or delivery queues are affected.
- First checks: Oban process health, database connectivity, retry reasons.
- What to inspect in Ops Dashboard: Worker retry backlog by queue.
- What to inspect in Audit Timeline: Stalled order/payment/delivery entities.
- Safe immediate action: Pause new sales if backlog affects paid flow.
- Unsafe actions to avoid: Do not delete jobs blindly.
- Recovery procedure: Restore worker capacity and clear root error.
- Verification after recovery: Backlog drains and state transitions resume.
- Escalation trigger: Backlog grows for two monitoring intervals.

## Ops dashboard unavailable

- Incident name: Ops dashboard unavailable.
- Symptoms: Operators cannot open `/dashboard/sales/ops`.
- Severity: High.
- First checks: Dashboard auth, app health, route availability, DB query health.
- What to inspect in Ops Dashboard: Not available.
- What to inspect in Audit Timeline: Use direct audit route if available.
- Safe immediate action: Pause launch if operators lose visibility.
- Unsafe actions to avoid: Do not continue blind first transactions.
- Recovery procedure: Restore app/dashboard access or provide approved read-only
  alternate evidence.
- Verification after recovery: Ops Dashboard loads with redacted data.
- Escalation trigger: Dashboard remains unavailable during launch window.

## Audit timeline unavailable

- Incident name: Audit timeline unavailable.
- Symptoms: Operators cannot inspect entity timelines.
- Severity: High.
- First checks: Dashboard auth, entity type/id, DB query health.
- What to inspect in Ops Dashboard: Affected order/payment/delivery counts.
- What to inspect in Audit Timeline: Not available.
- Safe immediate action: Pause destructive actions and manual resolutions.
- Unsafe actions to avoid: Do not resolve incidents without audit history.
- Recovery procedure: Restore Audit Timeline route/query health.
- Verification after recovery: Timeline loads for order, payment, ticket, and
  delivery entities.
- Escalation trigger: Timeline remains unavailable for incident orders.

## Suspected PII/token leak in logs

- Incident name: Suspected PII/token leak in logs.
- Symptoms: Logs or Sentry contain phone number, email, payment link, ticket
  link, access code, raw payload, or token hash.
- Severity: Critical.
- First checks: Identify source, time window, affected sink, and exposure scope.
- What to inspect in Ops Dashboard: Related delivery/payment incident pressure.
- What to inspect in Audit Timeline: Whether sensitive values appear in rendered
  audit entries.
- Safe immediate action: Restrict access to affected logs and pause leaking path.
- Unsafe actions to avoid: Do not copy sensitive value into incident notes.
- Recovery procedure: Rotate affected secrets/tokens if needed, purge or restrict
  logs according to policy, and fix redaction outside this docs slice.
- Verification after recovery: New logs are redacted and audit views are safe.
- Escalation trigger: Any customer token or provider secret is exposed.

