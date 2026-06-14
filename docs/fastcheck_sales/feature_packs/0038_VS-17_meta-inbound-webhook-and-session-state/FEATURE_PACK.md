# FastCheck Sales Feature Planning Pack — VS-17 Meta Inbound Webhook and Session State

**Pack ID:** `0038_VS-17_meta-inbound-webhook-and-session-state`  
**Slice:** `VS-17`  
**Slice name:** Meta Inbound Webhook and Session State  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** Implementation-ready provider-boundary + session-foundation slice  
**Primary area:** WhatsApp / Meta API / Webhook / Redis Session / Dedupe / Rate Limiting  
**Repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0038_VS-17_meta-inbound-webhook-and-session-state/`  
**Source docs:** `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md`, `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md`  
**Normalization:** Batch `0038_0040`, normalized 2026-06-14  
**Depends on:** VS-16, VS-00B, VS-21A  
**Blocks:** VS-18, VS-19, VS-20, VS-22, VS-23C  

---

## 1. Purpose

Implement the inbound Meta WhatsApp webhook boundary and hot session-state foundation for the WhatsApp-first production channel.

This slice should verify Meta webhook setup requests, validate inbound webhook signatures, persist or enqueue inbound messages safely, dedupe repeated Meta message IDs, maintain Redis hot session state, and create durable `FastCheck.Sales.Conversation` checkpoints when needed.

Critical boundary:

```text
VS-17 receives and normalizes WhatsApp inbound events.
VS-17 does not implement the number-only sales conversation flow.
VS-17 does not create checkout sessions.
VS-17 does not initialize Paystack.
VS-17 does not issue tickets.
VS-17 does not send ticket links.
```

The next slice, VS-18, consumes this inbound/session foundation to implement Afrikaans-first number-only conversation behavior.

---

## 2. FastCheckin Current-State Findings

Use FastCheckin conventions instead of inventing a separate app style.

Observed repo truth:

```text
Application module root: FastCheck
Web module root: FastCheckWeb
Router already separates browser/API/mobile pipelines.
Request metadata is already handled through FastCheckWeb.Plugs.LoggerMetadata.
Redis is already supervised as FastCheck.Redix through FastCheck.Redis.Connection.
Runtime config already reads secrets from environment variables.
Rate limiting configuration already exists and supports Redis storage for multi-node mobile-like traffic.
Req-style plain provider clients already exist through FastCheck.TickeraClient.
```

Therefore VS-17 should use:

```text
FastCheckWeb.Controllers.Webhooks.WhatsAppController
FastCheck.Messaging.WhatsApp.WebhookVerifier
FastCheck.Messaging.WhatsApp.InboundNormalizer
FastCheck.Messaging.WhatsApp.SessionStore
FastCheck.Messaging.WhatsApp.Dedupe
FastCheck.Workers.WhatsAppInboundWorker
FastCheck.Sales.Conversation
```

Do not place Meta verification or Redis session operations inside Ash resource actions.

---

## 3. Ultimate Outcome

After VS-17:

```text
Meta webhook verification challenge succeeds only with configured verify token.
Meta webhook POST signatures are verified before processing.
Inbound message payloads are normalized into a safe internal command shape.
Duplicate Meta message IDs are ignored idempotently.
Raw payload handling follows VS-00B security and retention policy.
Redis stores hot WhatsApp session state with TTL.
Postgres/Ash Conversation checkpoint is created or updated safely.
Inbound processing is handed to Oban quickly.
Webhook controller returns fast and does not run checkout/payment/ticket logic.
Rate limiting protects inbound abuse.
Logs contain correlation IDs but no PII-heavy payload dumps.
```

---

## 4. Scope

### In scope

```text
Webhook route for Meta verification GET.
Webhook route for inbound POST.
Verify-token checking for setup challenge.
Signature verification for inbound payloads.
Safe raw-body handling.
Inbound payload normalization.
Dedupe by provider message ID.
Redis hot session state with TTL.
Durable Conversation checkpoint create/resume.
Oban worker enqueue for inbound message processing.
Webhook response speed guarantees.
Rate-limit posture.
Security/log-redaction tests.
```

### Out of scope

```text
No number-only menu flow.
No Afrikaans/English conversation state machine implementation beyond storing baseline language/session fields.
No checkout/order creation.
No Redis inventory mutation.
No Paystack interaction.
No ticket issuing.
No secure ticket delivery.
No DeliveryAttempt creation.
No outbound Meta send except optional acknowledgement enqueue marker if VS-16 client is already available and explicitly mocked.
No WhatsApp utility template policy.
No admin support UI.
```

---

## 5. Recommended Files

```text
lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex
lib/fastcheck/messaging/whatsapp/webhook_verifier.ex
lib/fastcheck/messaging/whatsapp/inbound_normalizer.ex
lib/fastcheck/messaging/whatsapp/session_store.ex
lib/fastcheck/messaging/whatsapp/dedupe.ex
lib/fastcheck/messaging/whatsapp/message_command.ex
lib/fastcheck/workers/whatsapp_inbound_worker.ex
lib/fastcheck/sales/conversation.ex
config/runtime.exs
config/config.exs
test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs
test/fastcheck/messaging/whatsapp/webhook_verifier_test.exs
test/fastcheck/messaging/whatsapp/inbound_normalizer_test.exs
test/fastcheck/messaging/whatsapp/session_store_test.exs
test/fastcheck/workers/whatsapp_inbound_worker_test.exs
```

If the project already has equivalent modules from VS-16, extend them minimally.

---

## 6. Router Contract

Add the webhook under the public API surface, not the dashboard scope:

```text
scope "/api/v1/webhooks", FastCheckWeb.Webhooks do
  pipe_through :api

  get "/whatsapp", WhatsAppController, :verify
  post "/whatsapp", WhatsAppController, :receive
end
```

Rules:

```text
The GET verification route validates hub.mode, hub.verify_token, and hub.challenge.
The POST route verifies the Meta signature before storing/enqueuing anything.
The POST route must return quickly after durable store/enqueue.
Never mount inbound WhatsApp routes under browser/dashboard auth.
Never add checkout or ticket issuing directly to the controller.
```

---

## 7. Runtime Config Contract

Add runtime config using env vars, following existing FastCheckin secret conventions:

```text
META_WHATSAPP_VERIFY_TOKEN
META_WHATSAPP_APP_SECRET
META_WHATSAPP_PHONE_NUMBER_ID
META_WHATSAPP_BUSINESS_ACCOUNT_ID
META_WHATSAPP_API_VERSION
WHATSAPP_SESSION_TTL_SECONDS
WHATSAPP_DEDUPE_TTL_SECONDS
WHATSAPP_INBOUND_QUEUE_ENABLED
```

Rules:

```text
Production must fail boot if required Meta secrets are missing once WhatsApp is enabled.
Local/dev may use explicit dev placeholders only when provider calls are disabled/mocked.
Do not log app secret, access token, verify token, phone numbers, full message bodies, or full raw payloads.
```

---

## 8. Webhook Verification Contract

Module:

```text
FastCheck.Messaging.WhatsApp.WebhookVerifier
```

Required functions:

```text
verify_challenge(params, configured_verify_token)
verify_signature(raw_body, signature_header, app_secret)
```

Expected return shapes:

```text
{:ok, challenge}
{:error, :invalid_mode}
{:error, :invalid_verify_token}
{:error, :missing_challenge}

:ok
{:error, :missing_signature}
{:error, :invalid_signature}
{:error, :missing_app_secret}
```

Signature rules:

```text
Use constant-time comparison.
Verify against the raw request body, not re-encoded JSON.
Support the current Meta X-Hub-Signature-256 header format.
Do not process unsigned or invalidly signed POSTs.
```

---

## 9. Inbound Normalization Contract

Module:

```text
FastCheck.Messaging.WhatsApp.InboundNormalizer
```

Normalize Meta payloads into a bounded internal command:

```text
%FastCheck.Messaging.WhatsApp.MessageCommand{
  provider: "meta",
  provider_message_id: binary,
  phone_e164: binary,
  wa_id: binary,
  message_type: "text" | "interactive" | "button" | "unknown",
  text_body: binary | nil,
  interactive_payload: map | nil,
  received_at: DateTime.t(),
  raw_payload_hash: binary,
  correlation_id: binary,
  metadata: map
}
```

Rules:

```text
Support text messages as the primary VS-17 path.
Classify unsupported media/location/reaction/etc. as unknown or unsupported without crashing.
Do not execute business flow from normalizer.
Do not store full raw payload in Redis session.
Do not log full body text.
Truncate/validate message text length before command creation.
```

---

## 10. Dedupe Contract

Module:

```text
FastCheck.Messaging.WhatsApp.Dedupe
```

Redis key pattern:

```text
fastcheck:whatsapp:dedupe:message:{provider_message_id}
```

Operation:

```text
claim_message(provider_message_id, ttl_seconds)
```

Return shapes:

```text
{:ok, :new}
{:ok, :duplicate}
{:error, reason}
```

Rules:

```text
Use SET NX EX or equivalent through FastCheck.Redix.
Default TTL: 24 hours minimum.
Duplicate messages must not enqueue duplicate workers.
If Redis unavailable, choose a safe fallback: either durable DB idempotency if available or fail closed with 503/retryable response. Do not process duplicate-prone messages blindly during Redis outage.
```

---

## 11. Redis Session Store Contract

Module:

```text
FastCheck.Messaging.WhatsApp.SessionStore
```

Redis key pattern:

```text
fastcheck:whatsapp:session:{wa_id}
fastcheck:whatsapp:session:{phone_e164}
```

Stored fields:

```text
wa_id
phone_e164
conversation_id
state
preferred_language
last_provider_message_id
last_message_at
expires_at
needs_human
handoff_reason
correlation_id
```

Default TTL:

```text
24 hours for active WhatsApp session window unless VS-18 changes the policy.
```

Rules:

```text
Redis is hot session state.
Postgres/Ash Conversation is durable checkpoint state.
Do not store raw payload or full message body in Redis.
Do not store ticket links or customer-facing tokens in Redis session.
Update Redis only after signature/dedupe passes.
Refresh TTL on valid inbound customer messages.
```

---

## 12. Durable Conversation Checkpoint Contract

Use existing/planned `FastCheck.Sales.Conversation` from VS-01E.

Minimum fields to touch:

```text
phone_e164
wa_id
session_key
rate_limit_key
preferred_language
state
state_data
last_inbound_message_id
last_message_at
expires_at
needs_human
handoff_reason
```

Rules:

```text
If Conversation exists for wa_id/session, resume it.
If no Conversation exists, create a checkpoint in state new/main_menu_pending depending on accepted state matrix.
Do not implement the VS-18 menu flow here.
Do not mutate Order, CheckoutSession, PaymentAttempt, TicketIssue, or DeliveryAttempt in VS-17.
```

---

## 13. Worker Contract

Module:

```text
FastCheck.Workers.WhatsAppInboundWorker
```

Queue:

```text
whatsapp_inbound
```

Args:

```text
provider_message_id
wa_id
phone_e164
message_type
text_body_redacted_or_reference
conversation_id
correlation_id
received_at
raw_payload_hash
```

Rules:

```text
Worker must be idempotent by provider_message_id.
Worker must load fresh Conversation state before applying any transition.
In VS-17 worker may only record session/conversation checkpoint and emit telemetry.
VS-18 will add actual menu handling.
Do not make outbound calls in VS-17 except test-only mocked handoff hooks if explicitly approved.
```

---

## 14. RED/GREEN Test Plan

### RED tests first

```text
RED: GET /api/v1/webhooks/whatsapp returns challenge for valid verify token.
RED: GET verification rejects wrong token.
RED: POST rejects missing signature.
RED: POST rejects invalid signature.
RED: POST verifies signature against raw body.
RED: valid text message normalizes to MessageCommand.
RED: unsupported message type returns safe unsupported command without crashing.
RED: duplicate provider_message_id is not enqueued twice.
RED: Redis session stores only safe bounded fields and TTL.
RED: Conversation checkpoint is created or resumed.
RED: webhook controller returns quickly after enqueue.
RED: Redis unavailable during dedupe fails safely; no duplicate-prone blind processing.
RED: logs do not contain access token, app secret, verify token, phone_e164, full wa_id, full message body, raw payload, ticket URL, delivery token.
RED: inbound webhook does not create Order, CheckoutSession, PaymentAttempt, TicketIssue, Attendee, or DeliveryAttempt.
RED: inbound webhook does not call Paystack.
RED: inbound webhook does not call Meta outbound client.
```

### GREEN targets

```text
GREEN: Meta can verify webhook setup.
GREEN: Signed inbound messages are accepted, normalized, deduped, sessioned, and enqueued.
GREEN: Duplicate messages are idempotently ignored.
GREEN: Redis hot session and durable Conversation checkpoint align.
GREEN: VS-18 can build on stable inbound/session contracts.
```

---

## 15. Security and PII Rules

```text
Do not log phone_e164 in full.
Do not log wa_id in full.
Do not log message body in full.
Do not log raw payload.
Do not log signatures, app secret, verify token, or access token.
Do not store raw payload in Redis.
If raw payload is persisted in Postgres, follow VS-00B retention and access restrictions.
Use payload_hash for correlation instead of dumping payload.
Use constant-time comparison for signatures and verify token where applicable.
```

Admin/operator default visibility:

```text
Show masked phone/wa_id.
Show message type and timestamps.
Do not show raw payload by default.
```

---

## 16. Performance and Scaling Review

### Data placement

```text
Hot: Redis dedupe keys and WhatsApp session hash.
Warm: Conversation checkpoint cache if later added; not required in VS-17.
Cold: Postgres/Ash Conversation and optional inbound audit rows.
```

### Redis structures

```text
Dedupe: string key with SET NX EX.
Session: hash with TTL.
Rate limiting: existing PlugAttack/Redis or ETS storage, with Redis preferred for multi-node.
Activity feed: optional Redis list for support/debug only if bounded and PII-safe.
```

### TTL strategy

```text
Dedupe TTL: 24h minimum.
Session TTL: 24h default aligned to WhatsApp customer-service window.
Rate limit TTL: short windows, e.g. 60s/5m depending route.
No infinite Redis keys for inbound messages.
```

### Safety under concurrency

```text
Signature verification is CPU-bound and fast.
Webhook controller must avoid slow external HTTP.
Dedupe SET NX prevents duplicate worker enqueue.
Oban worker uniqueness by provider_message_id is a second guard, not the only guard.
No Postgres broad scans in webhook path.
Session writes are O(1) Redis operations.
```

### Indexes

Required or planned:

```text
sales_conversations(wa_id)
sales_conversations(phone_e164)
sales_conversations(session_key)
sales_conversations(state, expires_at)
sales_conversations(needs_human, last_message_at)
optional inbound audit unique(provider, provider_message_id)
optional inbound audit index(processing_status, inserted_at)
```

---

## 17. Observability

Telemetry names:

```text
[:fastcheck, :whatsapp, :webhook, :verified]
[:fastcheck, :whatsapp, :webhook, :signature_failed]
[:fastcheck, :whatsapp, :inbound, :received]
[:fastcheck, :whatsapp, :inbound, :deduped]
[:fastcheck, :whatsapp, :session, :updated]
[:fastcheck, :whatsapp, :conversation, :checkpointed]
[:fastcheck, :whatsapp, :worker, :enqueued]
[:fastcheck, :whatsapp, :worker, :failed]
```

Log metadata:

```text
request_id
correlation_id
provider_message_id_hash
wa_id_hash
message_type
processing_status
duration_ms
```

Forbidden log metadata:

```text
raw_payload
full phone_e164
full wa_id
message body
Meta access token
Meta app secret
verify token
signature
payment links
ticket links
delivery tokens
```

---

## 18. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-17 Meta Inbound Webhook and Session State in `JCSchoeman96/FastCheckin`. |
| Objective | Add the inbound Meta WhatsApp webhook boundary, signature verification, dedupe, Redis hot session state, and durable Conversation checkpointing so VS-18 can build the number-only WhatsApp sales flow safely. |
| Output | `lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex`; `lib/fastcheck/messaging/whatsapp/webhook_verifier.ex`; `inbound_normalizer.ex`; `session_store.ex`; `dedupe.ex`; `message_command.ex`; `lib/fastcheck/workers/whatsapp_inbound_worker.ex`; runtime config; tests for verification, signatures, dedupe, session TTL, Conversation checkpointing, log redaction, and boundary creep. |
| Note | Use FastCheckin conventions: public route under `/api/v1/webhooks/whatsapp` with `:api` pipeline; runtime secrets in `config/runtime.exs`; Redis via named `FastCheck.Redix`; Oban queue `whatsapp_inbound`; no external HTTP in webhook POST; no Paystack; no checkout; no ticket issuing; no DeliveryAttempt; no Attendee mutation; no outbound Meta sends. Redis structures: dedupe key `fastcheck:whatsapp:dedupe:message:{provider_message_id}` with SET NX EX and 24h TTL; session hash `fastcheck:whatsapp:session:{wa_id}` with 24h TTL; no raw payload or token storage in Redis. Required indexes: `sales_conversations(wa_id)`, `sales_conversations(phone_e164)`, `sales_conversations(session_key)`, `sales_conversations(state, expires_at)`, optional inbound audit unique `(provider, provider_message_id)`. Use constant-time signature comparison against raw body. Logs must redact phone, wa_id, body, raw payload, tokens, signatures, payment links, and ticket links. |
| Success | Meta webhook setup succeeds, signed inbound messages are accepted and queued exactly once, Redis session state is safe and bounded, durable Conversation checkpoints are created/resumed, and no Sales/payment/ticket side effects happen before VS-18/VS-19. |

---

## 19. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-17 — Meta Inbound Webhook and Session State in JCSchoeman96/FastCheckin.

Goal:
Add the inbound WhatsApp webhook boundary and session foundation only. Do not implement the WhatsApp sales conversation flow yet.

Use FastCheckin truths:
- Module root is FastCheck / FastCheckWeb.
- Public JSON routes belong under API-style scopes, not dashboard auth.
- Runtime secrets are read in config/runtime.exs.
- Redis is accessed through named FastCheck.Redix.
- Provider HTTP/client code stays in plain modules, not Ash resources.
- Sales.Conversation is durable checkpoint state; Redis is hot session state.

Implement:
1. GET /api/v1/webhooks/whatsapp verify challenge route.
2. POST /api/v1/webhooks/whatsapp receive route.
3. WebhookVerifier for verify-token and X-Hub-Signature-256 checks.
4. InboundNormalizer to map Meta payloads into MessageCommand.
5. Redis Dedupe using SET NX EX by provider_message_id.
6. Redis SessionStore with safe bounded fields and TTL.
7. WhatsAppInboundWorker with provider_message_id idempotency.
8. Conversation checkpoint create/resume only.
9. Tests for verification, invalid signature, raw-body signature, duplicate messages, session TTL, checkpointing, and log redaction.

Do not:
- create checkout sessions
- initialize Paystack
- issue tickets
- create DeliveryAttempt rows
- mutate Attendees
- mutate Redis inventory
- call Meta outbound client
- log full phone/wa_id/message/raw payload/tokens/signatures
- put webhook/session logic inside Ash resource actions

RED tests first. Keep the controller fast: verify, normalize, dedupe, store/checkpoint/enqueue, return.
```

---

## 20. Human Review Checklist

```text
[ ] Webhook routes are public API routes, not dashboard/browser routes.
[ ] GET verify challenge requires correct verify token.
[ ] POST verifies X-Hub-Signature-256 against raw body.
[ ] Invalid signatures are rejected and not enqueued.
[ ] Duplicate provider message IDs are ignored idempotently.
[ ] Redis session hash stores only safe bounded fields.
[ ] Session TTL is finite and refreshed on valid inbound messages.
[ ] Conversation checkpoint is created or resumed.
[ ] Worker is idempotent by provider_message_id.
[ ] No checkout/order/payment/ticket/attendee/delivery side effects exist.
[ ] No Paystack calls exist.
[ ] No outbound Meta sends exist.
[ ] Logs redact phone, wa_id, body, payload, token, and signature data.
[ ] Tests use fake request/body/signature data and do not require real Meta credentials.
[ ] Runtime config follows existing FastCheckin env-var patterns.
[ ] Rate-limit posture is documented.
```

---

## 21. Next Slice

```text
VS-18 — WhatsApp Number-Only Conversation Flow
```
