# VS-23C Final WhatsApp Launch Runbook

## Scope

WhatsApp is the primary customer interface for the first FastCheck Sales launch.
WhatsApp is not payment authority and is not ticket authority. Paystack
server-side verification remains authoritative for payment, and backend ticket
issuance remains authoritative for tickets.

Public web checkout remains deferred.

## Meta Cloud API Checklist

- Meta app is configured for the production app.
- WhatsApp number is approved and attached to the app.
- `META_WHATSAPP_PHONE_NUMBER_ID` is configured and not logged.
- `META_WHATSAPP_ACCESS_TOKEN` is configured and not logged.
- `META_WHATSAPP_APP_SECRET` is configured and not logged.
- Webhook URL points at `GET /api/v1/webhooks/whatsapp` for verification and
  `POST /api/v1/webhooks/whatsapp` for inbound messages.
- `META_WHATSAPP_VERIFY_TOKEN` matches Meta configuration and is not logged.
- Webhook subscription fields are configured for inbound messages.
- A test inbound message is received and persisted as a conversation event.
- A test outbound message is sent through the provider client.
- Provider failures route to retry, fallback-required, or manual review as
  documented.

## Inbound Webhook Checklist

- Signature verification is enabled.
- Duplicate inbound provider messages are deduped.
- Redis session/checkpoint behavior is verified.
- Conversation rows are persisted in `sales_conversations`.
- Inbound worker enqueue behavior is verified when queueing is enabled.
- Raw message body is not logged.
- Phone numbers, message bodies, and provider payloads are not stored in Oban
  args.
- Audit Timeline can inspect the conversation without exposing raw payloads.

## Conversation Flow Checklist

- Number-only flow starts from inbound message.
- Event selection works.
- Offer selection works.
- Quantity selection works.
- Checkout confirmation works.
- Checkout is created through Sales core with `source_channel = whatsapp`.
- Redis inventory is reserved by Sales core, not WhatsApp code.
- Paystack payment attempt is created through the approved payment path.
- Customer response reaches `payment_pending` state.
- Inbound response does not expose the Paystack payment link directly; payment
  link send is handled by the outbound worker.

## Payment Link Delivery Checklist

- `SendWhatsAppPaymentLinkWorker` is enqueued after checkout confirmation.
- Payment link send creates delivery visibility where current behavior records
  it.
- Outbound dedupe prevents duplicate sends for duplicate worker execution.
- Retryable provider errors are retried safely.
- Hard provider failures route to manual review or fallback handling.
- Logs do not contain customer phone numbers, payment links, access codes, or
  raw provider payloads.

## Ticket Link Delivery Checklist

- Payment is server-verified before ticket delivery.
- Ticket is issued before ticket delivery.
- `SendWhatsAppTicketLinkWorker` is the only ticket-link outbound path.
- Delivery token rotation is performed by current ticket delivery behavior before
  send where applicable.
- `sales_delivery_attempts` records send status.
- Plain ticket links are not stored in durable audit fields.
- Token hashes are not sent or logged.
- Duplicate worker execution does not send duplicate ticket links.

## 24-Hour Window Checklist

- Inside the Meta 24-hour customer-service window, ticket link sends use the
  session text message path.
- Outside the 24-hour window, ticket link sends use approved utility templates.
- English template name expected by current behavior: `fastcheck_ticket_ready_en`.
- Afrikaans/default ticket-ready template is provided by the local
  `TemplateCatalog`.
- Missing or unapproved template moves delivery to fallback-required/manual
  review.
- Provider auth or validation failure moves delivery to manual review.
- Retryable provider timeout releases dedupe for retry.

## WhatsApp Incident Procedures

Use [Incident Response](./INCIDENT_RESPONSE.md) for full incident structure.
WhatsApp-specific immediate responses:

- Webhook signature failures: pause inbound launch traffic, verify app secret,
  keep Paystack/webhook/ticket workers running.
- Redis unavailable during inbound dedupe: pause new WhatsApp entrypoints if
  duplicate messages are causing duplicate conversations; do not delete
  conversations.
- Meta API auth failure: pause outbound sends, rotate or restore credentials,
  move affected deliveries to manual review.
- Meta API rate limit: slow outbound sends, keep payment verification and ticket
  issuance running, review retry backlog.
- Template missing/unapproved: keep ticket issuance running, mark deliveries for
  manual review, do not invent a non-approved template.
- Outbound provider timeout: allow retryable jobs to retry; pause only if backlog
  grows faster than recovery.
- Duplicate inbound messages: verify dedupe and conversation checkpoint state.
- Duplicate outbound jobs: verify outbound dedupe and delivery attempts.
- Customer paid but no ticket link delivered: verify payment, issue state, and
  delivery attempts; resend only through approved worker path.
- Customer has ticket but scanner rejects it: inspect ticket, attendee, and
  invalidation audit before advising the customer.
- Customer messages after checkout expired: inspect checkout status and payment
  state; create a new checkout only through Sales core.
- Customer pays after checkout expired: route through manual review policy.
- Conversation stuck in payment-pending: verify payment attempt and webhook
  status, then inspect delivery attempts and Audit Timeline.
- DeliveryAttempt failed/fallback-required/manual-review: assign manual review
  operator and avoid exposing ticket links in public notes.

## WhatsApp Go/No-Go

- [ ] Inbound message reaches `POST /api/v1/webhooks/whatsapp`.
- [ ] Webhook signature verification succeeds.
- [ ] Duplicate inbound message does not create duplicate checkout effects.
- [ ] Outbound text send succeeds inside the 24-hour window.
- [ ] Approved template send succeeds outside the 24-hour window.
- [ ] WhatsApp checkout creates a Sales order with `source_channel = whatsapp`.
- [ ] Payment link is sent by `SendWhatsAppPaymentLinkWorker`.
- [ ] Paystack payment verifies server-side.
- [ ] Ticket is issued by backend issuer path.
- [ ] Ticket link is sent by `SendWhatsAppTicketLinkWorker`.
- [ ] Secure ticket page opens through `GET /t/:token`.
- [ ] Mobile sync sees issued attendee.
- [ ] Scanner accepts valid issued ticket.
- [ ] Revoked/refunded ticket is denied by scanner.
- [ ] Ops Dashboard and Audit Timeline show safe redacted state.

