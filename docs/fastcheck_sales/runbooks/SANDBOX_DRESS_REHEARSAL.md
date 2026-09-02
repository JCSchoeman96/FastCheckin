# Sandbox Dress Rehearsal

Use this checklist before production go/no-go. VS-22 E2E tests are the truth
source for the order of operations.

## Preconditions

- Action: Confirm current branch is release candidate branch and CI is green.
- Expected result: No pending runtime changes are required for rehearsal.
- Where to verify: GitHub checks, `git status --short --branch`.
- Failure response: Stop rehearsal and resolve the branch or CI issue outside
  this runbook.

## Steps

### 1. Setup test event

- Action: Select or create one sandbox event for the rehearsal.
- Expected result: Event is active, visible to Sales operators, and its
  `whatsapp_sales_enabled` gate is explicitly enabled for the rehearsal.
- Where to verify: `/dashboard/sales/ops` event filter and admin dashboard.
- Failure response: Stop; do not test against production launch event.

- Action: Confirm WhatsApp environment intent and provider scope.
- Expected result: `META_WHATSAPP_SANDBOX_MODE` is explicit for the rehearsal;
  the configured WABA and phone-number ID match the sandbox assets.
- Where to verify: Safe redacted application configuration and Meta dashboard.
- Failure response: Stop if sandbox/production intent or WABA/phone scope is
  ambiguous.

### 2. Setup offer and inventory

- Action: Create or select one active WhatsApp ticket offer with known quantity.
- Expected result: Offer is active and Redis availability matches approved
  quantity.
- Where to verify: Ops Dashboard, offer admin view, Redis inventory check.
- Failure response: Stop new checkouts and correct offer/inventory setup.

### 3. Start WhatsApp checkout

- Action: Send a test inbound WhatsApp message and complete number-only event,
  offer, quantity, and confirmation flow.
- Expected result: Sales order and checkout session are created with
  `source_channel = whatsapp`.
- Where to verify: `/dashboard/sales/ops`, Audit Timeline for order and
  conversation.
- Failure response: Pause WhatsApp entrypoint and inspect inbound webhook,
  Redis session, and conversation audit.

### 3A. Event gate and quantity checks

- Action: Disable the event gate after the conversation has displayed the event,
  then submit the stale confirmation.
- Expected result: New WhatsApp discovery and checkout fail closed without a new
  order or hold; existing paid/in-flight recovery remains available.
- Where to verify: Event admin, conversation state, order/hold counts, and audit
  timeline.
- Failure response: Stop if stale confirmation creates new Sales state or if
  disabling the gate invalidates existing truth.

- Action: Select a permitted multi-digit quantity when the offer maximum is at
  least ten.
- Expected result: AF/EN prompts show the selected offer maximum; values `10`
  and `12` are accepted when permitted, values above the maximum are rejected,
  menu index `10` is not treated as a menu option, and `0` remains Back.
- Where to verify: WhatsApp conversation and checkout order line.
- Failure response: Stop if checkout permits an above-maximum quantity or a
  second quantity ceiling appears.

### 4. Send payment link

- Action: Allow `SendWhatsAppPaymentLinkWorker` to send the payment link.
- Expected result: Customer receives a payment message; duplicate worker
  execution does not duplicate sends. The attempt is `provider_accepted` after
  Meta returns a WAMID, not `sent`/`delivered` until provider callbacks arrive.
- Where to verify: DeliveryAttempt rows, Oban job state, Ops Dashboard, and
  Audit Timeline for conversation/order.
- Failure response: Inspect Meta auth, rate limits, outbound dedupe, and manual
  review queue.

### 5. Complete Paystack sandbox payment

- Action: Pay using Paystack sandbox flow.
- Expected result: Paystack records payment under intended mode and reference.
- Where to verify: Paystack dashboard and local payment attempt.
- Failure response: Stop; do not issue tickets from provider UI alone.

### 6. Process webhook

- Action: Confirm Paystack webhook reaches `POST /api/sales/paystack/webhook`.
- Expected result: `sales_payment_events` row is stored and queryable.
- Where to verify: Ops Dashboard recent failures, Audit Timeline for payment
  event.
- Failure response: Inspect webhook URL, signature, app logs, and provider retry
  state.

### 7. Verify transaction server-side

- Action: Let `VerifyPaymentWorker` or approved verification path verify payment.
- Expected result: Payment attempt reaches verified success.
- Where to verify: Order operations page and Audit Timeline for payment attempt.
- Failure response: Do not issue ticket; inspect Paystack verify response,
  timeout, mismatch, or pending state.

### 8. Issue ticket

- Action: Let `IssueTicketsWorker` issue the order.
- Expected result: One ticket issue and one attendee are created per purchased
  unit; order reaches `ticket_issued`.
- Where to verify: Order operations page, Audit Timeline, DB read-only checks.
- Failure response: Keep issuance recovery running; escalate if payment is
  verified but ticket is not issued.

### 9. Send ticket link

- Action: Trigger the status/ticket delivery path and allow
  `SendWhatsAppTicketLinkWorker` to send.
- Expected result: Ticket link is sent once; the DeliveryAttempt records
  `provider_accepted` first and later signed Meta `sent`, `delivered`, `read`, or
  `failed` evidence when available.
- Where to verify: DeliveryAttempt rows, status-evidence records, Ops Dashboard,
  and Audit Timeline for delivery attempt.
- Failure response: Inspect 24-hour window policy, template availability, Meta
  auth, and manual review queue.

- Action: If a ticket-link request times out or loses its connection after
  dispatch, treat it as ambiguous transport.
- Expected result: The attempt enters `manual_review`; the worker does not
  release dedupe, retry automatically, or rotate another secure token. A
  definitively rejected provider response may follow the bounded retry policy.
- Where to verify: DeliveryAttempt status, dedupe state, worker result, and
  operator review queue.
- Failure response: Stop if an ambiguous outcome sends a second link.

### 10. Open secure ticket page

- Action: Open the received secure ticket link.
- Expected result: Ticket page renders valid ticket and no internal token hashes.
- Where to verify: Browser page and Audit Timeline.
- Failure response: Inspect ticket issue state and delivery token validity; do
  not paste ticket link into public logs.

### 11. Mobile sync

- Action: Log in scanner for the event and run attendee sync.
- Expected result: Issued attendee appears in mobile sync response.
- Where to verify: Scanner app, `GET /api/v1/mobile/attendees`, Ops Dashboard
  scanner visibility count.
- Failure response: Inspect mobile JWT config, event scope, attendee row, and
  event sync version.

- Action: For the mixed-source regression event, sync after a Tickera-origin
  attendee and a `fastcheck_sales` attendee are both present.
- Expected result: Both eligible attendees are visible; the Sales ticket scans
  successfully, and later Sales revocation invalidates only the Sales attendee.
  Tickera reconciliation does not overwrite or invalidate the Sales row, and the
  Tickera attendee remains eligible.
- Where to verify: Mobile sync, scanner acceptance, attendee source fields, and
  invalidation/audit records.
- Failure response: Stop mixed-source approval and create a blocker if source or
  scanner identity collides.

### 12. Scanner acceptance

- Action: Scan the valid issued ticket.
- Expected result: `POST /api/v1/mobile/scans` returns success and scan batch is
  persisted.
- Where to verify: Scanner app, mobile scan endpoint, order/audit views.
- Failure response: Inspect attendee scanner fields and DB authority before
  retrying.

### 13. Admin revocation/refund

- Action: Revoke or refund the test ticket only if rehearsal approval includes
  destructive test actions.
- Expected result: Revocation requires reason and changes ticket/attendee
  scanner visibility.
- Where to verify: `/dashboard/sales/orders/:id`, Audit Timeline, invalidation
  count.
- Failure response: Stop destructive actions and escalate to refund/revocation
  operator.

### 14. Scanner denial after revocation

- Action: Attempt to scan revoked/refunded ticket.
- Expected result: Scanner rejects the ticket as no longer valid.
- Where to verify: Scanner app, `POST /api/v1/mobile/scans`, Audit Timeline.
- Failure response: Pause sales if a should-be-revoked ticket is accepted.

### 15. Manual review scenario

- Action: Run a controlled mismatch or late-payment scenario in sandbox.
- Expected result: No ticket is issued and order moves to manual review.
- Where to verify: `/dashboard/sales/ops`, `/dashboard/sales/reviews`, Audit
  Timeline.
- Failure response: Stop launch if mismatch issues tickets or bypasses review.

### 16. Expired checkout scenario

- Action: Let or force a sandbox checkout expire before payment.
- Expected result: Hold releases once, order/session expire, late verified
  payment routes to manual review.
- Where to verify: Redis inventory, Ops Dashboard, Audit Timeline.
- Failure response: Pause new checkouts if holds do not release or double-release.

### 17. Duplicate webhook scenario

- Action: Replay the same Paystack sandbox webhook.
- Expected result: Duplicate webhook is idempotent and no duplicate payment
  effects occur.
- Where to verify: Payment event row, order status, Audit Timeline.
- Failure response: Pause payment launch if duplicate webhook creates duplicate
  effects.

### 18. Duplicate worker scenario

- Action: Re-run payment verification and ticket issuance workers for the same
  order in sandbox.
- Expected result: One verified payment effect, one ticket issue per purchased
  unit, one attendee per purchased unit.
- Where to verify: DB read-only counts, order page, Audit Timeline.
- Failure response: Stop; duplicate ticket or attendee creation is a launch
  blocker.

### 19. Ops dashboard verification

- Action: Open `/dashboard/sales/ops`.
- Expected result: Status counts, provider acceptance versus Meta delivery
  evidence, failures, manual review, delivery failures, scanner visibility, and
  Oban backlog are visible and redacted.
- Where to verify: Ops Dashboard.
- Failure response: Escalate if operator cannot see launch state.

### 20. Audit timeline verification

- Action: Open Audit Timeline for order, payment attempt, ticket issue, delivery
  attempt, and conversation.
- Expected result: Safe redacted timeline entries load.
- Where to verify: `/dashboard/sales/audit/:entity_type/:entity_id`.
- Failure response: Escalate if timeline is unavailable or exposes sensitive
  data.

### 21. Log redaction spot checks

- Action: Inspect application logs for rehearsal correlation.
- Expected result: No phone numbers, emails, payment links, ticket links, access
  codes, raw payloads, or token hashes are present.
- Where to verify: App logs and Sentry if enabled.
- Failure response: Treat as PII/token leak incident and follow incident runbook.

### 22. Pass/fail signoff

- Action: Launch owner, operator, and developer/admin review all checklist
  evidence.
- Expected result: Every step is pass or has an accepted mitigation.
- Where to verify: Go/No-Go checklist.
- Failure response: No production launch until failures are resolved or formally
  accepted.
