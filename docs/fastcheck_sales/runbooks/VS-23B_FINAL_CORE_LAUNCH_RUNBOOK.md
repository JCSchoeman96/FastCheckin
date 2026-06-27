# VS-23B Final Core Launch Runbook

## Scope

The selected launch scope is WhatsApp-first paid core. Internal pilot sales and
admin-assisted sales are allowed before launch as controlled secondary paths
over the same Sales core. Public web checkout is deferred and must not be part
of the first launch.

Use VS-22 E2E tests as the launch-flow truth: checkout, Redis hold, Paystack
webhook, server-side verification, ticket issuance, secure ticket page, mobile
sync, scanner acceptance, duplicate webhook and worker idempotency, manual
review, expiry, and revocation scanner denial.

Use VS-21B operator views as the visibility truth:

- `/dashboard/sales/ops`
- `/dashboard/sales/audit/:entity_type/:entity_id`

## Preconditions

- CI is green on current `main`.
- `mix precommit` is green locally or in CI.
- `mix test --only e2e` is green for the VS-22 launch-flow suite.
- Paystack sandbox or live mode is selected deliberately.
- Paystack public key, secret key, callback URL, and webhook URL are configured.
- Meta Cloud API credentials are verified for the WhatsApp launch path.
- Redis is reachable.
- Postgres is reachable and all migrations are applied.
- Oban is running and processing the Sales queues.
- Dashboard auth works for an assigned operator.
- Ops Dashboard opens at `/dashboard/sales/ops`.
- Audit Timeline opens at `/dashboard/sales/audit/:entity_type/:entity_id`.
- Mobile login, attendee sync, and scan upload are verified.
- At least one active event exists.
- At least one active ticket offer exists for the launch event.
- Inventory quantity is configured for the launch offer.
- Admin/operator access is confirmed.
- Manual review operator is assigned.
- Refund/revocation operator is assigned.
- Incident contact list is confirmed.

## Environment Checklist

Verify each variable is present where required, is not printed in logs, and is
not pasted into tickets, chat, screenshots, or runbook evidence.

Core production secrets and runtime:

- `SECRET_KEY_BASE` is present and long enough for production boot.
- `ENCRYPTION_KEY` is present and long enough for production boot.
- `SALES_HOLD_TOKEN_PEPPER` is present and long enough for production boot.
- `TICKET_TOKEN_PEPPER` is present and long enough for production boot.
- `DATABASE_URL` points at the intended production database.
- `REDIS_URL` points at the intended Redis instance.
- `SALES_INTERNAL_PILOT_ENABLED` is set deliberately for launch posture.
- `DASHBOARD_USERNAME` and `DASHBOARD_PASSWORD` are set for operator access.
- `SENTRY_DSN` is present if Sentry is part of the release.

Paystack:

- `PAYSTACK_ENABLED` is set deliberately.
- `PAYSTACK_ENVIRONMENT` matches the rehearsal or live launch mode.
- `PAYSTACK_BASE_URL` points at the intended Paystack API host.
- `PAYSTACK_PUBLIC_KEY` is present and not logged.
- `PAYSTACK_SECRET_KEY` is present and not logged.
- `PAYSTACK_CALLBACK_URL` points at the deployed callback endpoint.
- `PAYSTACK_WEBHOOK_URL` points at `POST /api/sales/paystack/webhook`.
- `PAYSTACK_ALLOWED_CHANNELS` matches the intended payment channels.
- `PAYSTACK_TIMEOUT_MS` is a positive value.
- `PAYSTACK_INITIALIZING_STALE_AFTER_SECONDS` is understood by operators.

WhatsApp and Meta:

- `META_WHATSAPP_ENABLED` is set deliberately.
- `META_GRAPH_API_BASE_URL` and `META_GRAPH_API_VERSION` are configured.
- `META_WHATSAPP_PHONE_NUMBER_ID` is present and not logged.
- `META_WHATSAPP_BUSINESS_ACCOUNT_ID` is present if required.
- `META_WHATSAPP_ACCESS_TOKEN` is present and not logged.
- `META_WHATSAPP_APP_SECRET` is present and not logged.
- `META_WHATSAPP_VERIFY_TOKEN` is present and not logged.
- `META_WHATSAPP_REQUEST_TIMEOUT_MS` is a positive value.
- `META_WHATSAPP_RECEIVE_TIMEOUT_MS` is a positive value.
- `META_WHATSAPP_SANDBOX_MODE` matches the target environment.
- `WHATSAPP_SESSION_TTL_SECONDS` is understood by operators.
- `WHATSAPP_DEDUPE_TTL_SECONDS` is understood by operators.
- `WHATSAPP_INBOUND_QUEUE_ENABLED` is enabled for launch unless deliberately
  paused by incident response.

Mobile and scanner runtime:

- `MOBILE_JWT_SECRET` is present and not logged.
- `MOBILE_JWT_TTL_SECONDS`, `MOBILE_JWT_ISSUER`, and `MOBILE_JWT_ALGORITHM`
  match the Android scanner expectation.
- `MOBILE_SCAN_CHUNK_SIZE` is set to a value the server can process reliably.
- `MOBILE_SCAN_LIVE_NAMESPACE` is the production namespace.
- `MOBILE_SCAN_FORCE_ENQUEUE_FAILURE` is disabled for launch.
- `SCANNER_STATS_RECONCILE_MS` is set deliberately.
- `SCANNER_FORCE_REFRESH_EVERY_N_SCANS` is set deliberately.
- `SCANNER_WARMUP_ON_LOGIN` is set deliberately.
- `SCANNER_SCANNING_ALLOWED_TTL_MS` is set deliberately.
- `MOBILE_SYNC_PARALLEL`, `MOBILE_SYNC_MAX_CONCURRENCY`, and
  `MOBILE_SYNC_TASK_TIMEOUT_MS` are set for production load.

DB and runtime posture:

- `DATABASE_POOLING_MODE` matches the deployment topology.
- `DB_PREPARE_MODE` is compatible with the pooling mode.
- `ALLOW_UNKNOWN_PAYMENT_STATUS` is disabled unless an explicit launch decision
  says otherwise.
- `CACHE_ENABLED` matches the release posture.

## Database And Migrations Checklist

- Confirm Postgres accepts application connections.
- Confirm migrations are applied.
- Confirm no pending migrations remain.
- Confirm the launch database is not pointing at rehearsal data.
- Confirm no stale test data exists in the production launch event.
- Confirm event and offer data exists for the launch event.
- Confirm these tables are queryable without destructive SQL:
  - `sales_orders`
  - `sales_checkout_sessions`
  - `sales_payment_attempts`
  - `sales_payment_events`
  - `sales_ticket_issues`
  - `sales_delivery_attempts`
  - `sales_state_transitions`
  - `sales_conversations`
  - `attendees`
  - `attendee_invalidation_events`
- Confirm Ops Dashboard query windows load quickly.
- Confirm Audit Timeline pagination works for `order`, `payment_attempt`,
  `payment_event`, `ticket_issue`, `delivery_attempt`, `conversation`, and
  `attendee_invalidation_event`.

## Redis And Inventory Checklist

- Confirm Redis is reachable from the app.
- Confirm inventory keys exist only for intended launch offers.
- Confirm launch offer availability matches the approved quantity.
- Confirm no stale hold keys remain for the launch event.
- Confirm no unexpected reservation or hold backlog exists.
- Confirm checkout expiry/release behavior is understood by the launch operator.
- Confirm Redis restart/recovery procedure is available in
  [Rollback and Pause Sales](./ROLLBACK_AND_PAUSE_SALES.md).
- Do not manually edit inventory keys during launch unless following the
  documented recovery procedure.

## Paystack Checklist

- Confirm Paystack is in the intended mode: sandbox for rehearsal, live for
  launch.
- Confirm transaction initialization creates a local `PaymentAttempt`.
- Confirm Paystack returns a provider reference.
- Confirm webhook endpoint is configured as `POST /api/sales/paystack/webhook`.
- Confirm webhook secret/signature verification succeeds.
- Confirm server-side verification succeeds before ticket issuance.
- Confirm duplicate webhook processing is idempotent.
- Confirm duplicate `PaystackWebhookWorker` and `VerifyPaymentWorker` execution
  does not duplicate payment effects.
- Confirm failed and pending provider statuses do not issue tickets.
- Confirm amount, currency, and reference mismatches route to safe states and
  manual review.
- Confirm no tickets issue from webhook receipt alone.

## Ticket Issuance Checklist

- Confirm paid verified orders are issued through `IssueTicketsWorker`.
- Confirm one `sales_ticket_issues` row is created per purchased ticket unit.
- Confirm one `attendees` row is created per purchased ticket unit.
- Confirm duplicate issuer worker execution does not duplicate tickets or
  attendees.
- Confirm partial failure and retry behavior is documented for operators.
- Confirm ticket codes, QR material, delivery tokens, token hashes, ticket URLs,
  and payment URLs are not logged.
- Confirm order status reaches `ticket_issued` only after issue and attendee rows
  exist.

## Secure Ticket Page Checklist

- Confirm secure ticket links resolve through `GET /t/:token`.
- Confirm a valid delivery token renders the expected ticket page.
- Confirm expired, revoked, or invalid tokens do not expose a valid ticket.
- Confirm token hashes are not rendered in HTML.
- Confirm ticket page behavior after revocation/refund shows no valid scannable
  ticket.

## Scanner And Mobile Checklist

- Confirm mobile login issues an event-scoped JWT.
- Confirm `GET /api/v1/mobile/attendees` returns issued attendees for the event.
- Confirm `POST /api/v1/mobile/scans` accepts a valid issued ticket.
- Confirm a revoked/refunded ticket is rejected by the scan endpoint.
- Confirm revocation creates an `attendee_invalidation_events` row.
- Confirm event sync version changes when scanner-visible state changes.
- Confirm stale mobile state is denied by database authority.
- Confirm scanner runtime settings listed in the environment checklist are
  deliberately configured.

## Admin-Assisted And Internal Pilot Checklist

- Confirm both paths use shared Sales core.
- Confirm both paths reserve Redis inventory.
- Confirm both paths create Paystack payment attempts through the approved path.
- Confirm both paths require server-side Paystack verification before issuance.
- Confirm neither path bypasses `IssueTicketsWorker`.
- Confirm destructive admin actions require an explicit reason.
- Confirm destructive actions are visible in Audit Timeline.
- Confirm public web checkout remains deferred and out of the first launch.

## Ops Dashboard And Audit Timeline

Open `/dashboard/sales/ops` and verify:

- Orders by status show expected launch event counts.
- Payment failures and mismatches are visible without raw payloads.
- Manual review queue count is visible.
- Delivery failures and fallback-required counts are visible.
- Scanner visibility pending count is visible.
- Oban retry backlog is visible.
- Filters by event and source channel work.

Open `/dashboard/sales/audit/:entity_type/:entity_id` and verify:

- Order, payment, ticket, delivery, and conversation timelines load.
- Timeline entries are newest-first and paginated.
- Metadata is redacted.
- No raw provider payload, buyer PII, token URL, payment URL, ticket URL, access
  code, or token hash is visible.

## Manual Review Workflow

Manual review may be caused by payment mismatches, late payment after checkout
expiry, unmatched webhooks, delivery fallback, provider auth/validation failure,
or operator intervention.

Operator steps:

1. Open `/dashboard/sales/ops`.
2. Check manual review count and recent payment failures.
3. Open the affected order in `/dashboard/sales/orders/:id`.
4. Open Audit Timeline for the order and linked payment attempt/event.
5. Confirm whether payment was server-verified, mismatched, failed, pending, or
   unmatched.
6. If customer communication is needed, use approved support channels and do not
   paste payment URLs, ticket URLs, tokens, phone numbers, or email addresses
   into public notes.
7. Escalate to developer/admin if state is contradictory or scanner visibility
   cannot be verified.

Operators must not manually mark orders paid, manually create tickets, manually
edit attendee scanner state, or manually change Redis inventory.

Pause sales if manual review grows faster than the assigned operator can clear
it or if verified payments are not issuing tickets.

## Refund And Revocation Workflow

- Only the assigned refund/revocation operator may perform revocation/refund
  actions.
- A concrete reason is required.
- Expected final state: ticket issue revoked, attendee not scannable, invalidation
  event appended, event sync version changed, secure ticket page no longer
  exposes a valid scannable ticket, scanner rejects the ticket.
- Verify the order and ticket in Audit Timeline.
- Verify scanner denial through mobile scan endpoint or controlled scanner test.
- Customer communication must avoid exposing tokens, payment references, ticket
  URLs, or internal IDs beyond approved support policy.

## Pause And Rollback Summary

Pause in this order:

1. Stop new customer entrypoints.
2. Stop WhatsApp outbound checkout/payment-link creation if needed.
3. Stop admin-assisted and internal-pilot checkout creation.
4. Hide public-facing launch links if any exist.

Keep these running:

- Paystack webhook ingestion.
- Payment verification workers.
- Ticket issuance recovery.
- Checkout expiry cleanup.
- Manual review.
- Refund/revocation safety.
- Scanner/mobile sync.

Do not delete payment events, delivery attempts, state transitions, tickets, or
attendees. Do not manually edit scanner state. Do not manually change Redis
inventory except through the documented recovery procedure.

## First Live Transaction Checklist

- Select the launch event.
- Confirm active offer availability.
- Confirm Ops Dashboard baseline counts.
- Start one controlled WhatsApp checkout.
- Send payment link.
- Complete Paystack payment.
- Confirm Paystack webhook arrived.
- Confirm server-side verification reached verified success.
- Confirm `IssueTicketsWorker` issued the ticket.
- Confirm ticket link delivery attempt is recorded.
- Open the secure ticket page.
- Sync mobile attendees.
- Scan the ticket.
- If approved for launch rehearsal, revoke/refund the test ticket and confirm
  scanner denial.
- Confirm `/dashboard/sales/ops` and Audit Timeline show safe, redacted state.

