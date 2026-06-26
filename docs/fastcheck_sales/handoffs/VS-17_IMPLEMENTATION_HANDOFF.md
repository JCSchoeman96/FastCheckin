# VS-17 Implementation Handoff

## Status

Merged.

PR: #400 — feat(whatsapp): add VS-17 inbound webhook session state  
Merge commit: `ece576806e1fd56901578d6b88b9602166972541`  
Merged at: 2026-06-26T14:21:36Z  
Branch: `vs-17-meta-inbound-webhook-and-session-state`

## What Changed

VS-17 added Meta WhatsApp inbound webhook ingress at
`GET/POST /api/v1/webhooks/whatsapp`, raw-body `X-Hub-Signature-256`
verification, inbound payload normalization into bounded `MessageCommand`
structs, Redis dedupe and hot session state, durable `Conversation`
checkpoint create/resume, and a no-op `WhatsAppInboundWorker` handoff.

Inbound processing is gated on `META_WHATSAPP_ENABLED=true` plus webhook
secrets (`app_secret`, `verify_token`). Redis dedupe fails closed on outage;
post-dedupe failures release the dedupe key so Meta can retry. Oban job args,
Redis session hashes, and logs avoid full phone, `wa_id`, message body, raw
payload, signatures, and provider secrets.

No migrations, outbound Meta sends, checkout/order/payment/ticket/delivery
side effects, or number-only menu flow were added.

## Files Changed

- `lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex` — GET verify
  challenge and POST signed ingress; dedupe → checkpoint → session → Oban
  pipeline with post-dedupe compensation.
- `lib/fastcheck/messaging/whatsapp/webhook_verifier.ex` — pure Meta challenge
  and constant-time raw-body HMAC verification.
- `lib/fastcheck/messaging/whatsapp/inbound_normalizer.ex` — Meta webhook JSON
  to `MessageCommand` list; supports `text`, `interactive`, and `button`; drops
  unsupported types safely.
- `lib/fastcheck/messaging/whatsapp/message_command.ex` — bounded inbound struct
  with safe `Inspect`/`safe_summary/1`.
- `lib/fastcheck/messaging/whatsapp/dedupe.ex` — Redis `SET NX EX` on
  `fastcheck:whatsapp:dedupe:message:{provider_message_id}`; release on
  downstream failure.
- `lib/fastcheck/messaging/whatsapp/session_store.ex` — Redis hash session at
  `fastcheck:whatsapp:session:wa:{hash}` and `...:phone:{hash}` with redacted
  fields and TTL.
- `lib/fastcheck/messaging/whatsapp/inbound_checkpoint.ex` — transactional
  `Conversation` create/resume via advisory lock on `wa_id`.
- `lib/fastcheck/workers/whatsapp_inbound_worker.ex` — `:whatsapp_inbound`
  queue worker; loads conversation and emits safe telemetry only (no menu flow).
- `lib/fastcheck/messaging/whatsapp/config.ex` — extended with
  `validate_for_webhook/0`, `session_ttl_seconds`, `dedupe_ttl_seconds`, and
  `inbound_queue_enabled`.
- `lib/fastcheck/sales/conversation.ex` — `get_by_id`, `create_inbound_checkpoint`,
  and `update_inbound_checkpoint` actions for VS-17 checkpointing.
- `lib/fastcheck_web/router.ex` — routes under `/api/v1/webhooks` on `:webhook`
  pipeline (raw-body dependent).
- `lib/fastcheck_web/plugs/raw_body_reader.ex` — retains raw body for WhatsApp
  webhook POSTs only.
- `lib/fastcheck_web/plugs/rate_limiter.ex` — `throttle_whatsapp_webhook` rule
  (default 120/min per request identity).
- `lib/fastcheck_web/endpoint.ex` — narrow raw-body retention path for WhatsApp
  webhook.
- `config/config.exs` — `:whatsapp_inbound` Oban queue; session/dedupe TTL and
  inbound-queue defaults.
- `config/runtime.exs` — env-driven webhook secrets, TTLs, inbound-queue flag,
  and `whatsapp_webhook_limit`.
- `test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs` —
  verify challenge, signature, dedupe, no-op payloads, PII-safe job args,
  compensation retry.
- `test/fastcheck/messaging/whatsapp/{webhook_verifier,dedupe,inbound_normalizer,inbound_checkpoint,session_store}_test.exs` —
  unit coverage for each inbound boundary module.
- `test/fastcheck/workers/whatsapp_inbound_worker_test.exs` — no-op worker,
  arg sanitization, safe telemetry.
- `test/support/whatsapp_webhook_test_support.ex` — signed payload fixtures and
  test config helpers.
- `test/fastcheck/messaging/whatsapp/boundary_test.exs` — approves inbound
  controller/worker paths; VS-16 provider modules remain isolated.
- Historical `test/fastcheck/sales/*_boundary_test.exs` and
  `test/support/sales_boundary_allowlist.ex` — allowlist updates only.

## Contracts Now Available

- `GET /api/v1/webhooks/whatsapp` — Meta verify-token challenge when
  `hub.mode=subscribe` and token matches configured `verify_token`.
- `POST /api/v1/webhooks/whatsapp` — signed inbound ingress on `:webhook`
  pipeline with `conn.private[:raw_body]` for HMAC verification.
- `FastCheck.Messaging.WhatsApp.WebhookVerifier.verify_challenge/2` and
  `verify_signature/3` — authoritative signature/challenge checks.
- `FastCheck.Messaging.WhatsApp.InboundNormalizer.normalize/2` — returns
  `{:ok, [MessageCommand.t()]}` or `{:error, :malformed_payload}`.
- `FastCheck.Messaging.WhatsApp.Dedupe.claim_message/2` and `release_message/1`
  — provider-message dedupe with fail-closed Redis errors.
- `FastCheck.Messaging.WhatsApp.SessionStore.put_session/3` and key helpers —
  bounded Redis hot session with hashed keys and redacted hash fields.
- `FastCheck.Messaging.WhatsApp.InboundCheckpoint.checkpoint/2` — durable
  `Conversation` create/resume inside a DB transaction with advisory lock.
- `FastCheck.Sales.Conversation` actions `create_inbound_checkpoint`,
  `update_inbound_checkpoint`, and `get_by_id` — checkpoint persistence contract.
- `FastCheck.Workers.WhatsAppInboundWorker` on `:whatsapp_inbound` queue with
  Oban uniqueness on `provider_message_id`; sanitized args only.
- `FastCheck.Messaging.WhatsApp.Config.validate_for_webhook/0` — enabled +
  `app_secret` + `verify_token` + positive TTLs + inbound queue enabled.
- Default Redis TTLs: session and dedupe both 86_400 seconds (24h), overridable
  via `META_WHATSAPP_SESSION_TTL_SECONDS` and `META_WHATSAPP_DEDUPE_TTL_SECONDS`.

## Decisions Applied

- Inbound/session foundation only; no number-only sales conversation flow.
- Reuses VS-16 `Config` namespace and VS-21A `Redactor`/`Correlation` for safe
  logging and metadata.
- Raw-body signature verification on the `:webhook` pipeline, matching Paystack
  webhook posture.
- Redis dedupe fails closed; post-dedupe enqueue/persist failure releases dedupe
  key for provider retry.
- Redis session keys hash `wa_id` and `phone_e164`; Oban args store hashes and
  redacted references, not raw PII.
- Unsupported message types and status-only payloads return HTTP 200 with no
  checkpoint/session/worker side effects.
- `preferred_language` defaults to `"af"` at checkpoint creation.
- No database migrations in this slice; uses existing `sales_conversations`
  table from VS-01E.
- No outbound Meta HTTP calls in production paths.

## Boundaries Still Enforced

- No Afrikaans number-only menu or conversation state machine (VS-18).
- No checkout/order creation, Paystack calls, or payment initialization.
- No ticket issuance, secure ticket links, or `DeliveryAttempt` creation.
- No outbound Meta `Client.send_text/3` or `send_template/4` from inbound paths.
- No Redis inventory/`ReservationLedger` mutation.
- No `Attendee` mutation, scanner/mobile/Android changes, or admin/customer UI.
- No new migrations or Ash resources beyond `Conversation` action extensions.
- Worker performs telemetry/logging only; no sales workflow side effects.

## Tests Added Or Updated

- `test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs` —
  verify challenge, signature rejection, signed text ingress, dedupe,
  status/unsupported no-ops, malformed JSON safety, post-dedupe compensation.
- `test/fastcheck/messaging/whatsapp/webhook_verifier_test.exs` — challenge and
  HMAC edge cases.
- `test/fastcheck/messaging/whatsapp/inbound_normalizer_test.exs` — text,
  interactive/button normalization; unsupported types dropped.
- `test/fastcheck/messaging/whatsapp/dedupe_test.exs` — claim, duplicate,
  release behavior.
- `test/fastcheck/messaging/whatsapp/session_store_test.exs` — bounded hash
  fields and TTL.
- `test/fastcheck/messaging/whatsapp/inbound_checkpoint_test.exs` —
  create/resume `Conversation` checkpoint.
- `test/fastcheck/workers/whatsapp_inbound_worker_test.exs` — sanitized args,
  conversation load, safe telemetry.
- `test/fastcheck/messaging/whatsapp/boundary_test.exs` — approves VS-17
  controller/worker paths; VS-16 provider modules stay decoupled.
- `test/fastcheck/messaging/whatsapp/config_test.exs` — webhook validation and
  TTL config.
- `test/fastcheck/sales/conversation_resource_skeleton_test.exs` and boundary
  allowlist tests — checkpoint actions allowed; no new forbidden Sales paths.

## Verification Reported

From PR #400:

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test test/fastcheck/messaging/whatsapp/`
- `mix test test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs`
- `mix test test/fastcheck/workers/whatsapp_inbound_worker_test.exs`
- `mix test test/fastcheck/sales/conversation_resource_skeleton_test.exs test/fastcheck/sales/conversation_resource_migrations_test.exs test/fastcheck/sales/vs_01e_boundary_test.exs test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs`
- `mix test test/fastcheck/observability/`
- `mix test test/fastcheck_web/controllers/webhooks/paystack_controller_test.exs`
- `mix test test/fastcheck/payments/paystack/`
- `mix test` — 963 tests, 0 failures, 4 skipped
- `mix precommit` — Credo no issues; 963 tests, 0 failures, 4 skipped
- GitHub CI run 896 passed on `bc202683a46460f0ae69b8d642aa82192d18ce96`

## Known Limitations

- `WhatsAppInboundWorker` is a no-op handoff; it does not run menu logic or call
  Sales checkout facades.
- `Conversation.state` remains `"new"`; VS-18 owns state-machine transitions.
- Only `text`, `interactive`, and `button` inbound types normalize; media and
  other Meta types are accepted as HTTP 200 no-ops.
- Hot session stores checkpoint metadata only; ephemeral menu selections belong
  in VS-18.
- Webhook ingress requires WhatsApp enabled plus inbound secrets even though no
  outbound customer messages are sent yet.
- No inbound audit table; dedupe relies on Redis keys with 24h TTL minimum.

## Next Agent Guidance

**Reuse:**

- `FastCheckWeb.Webhooks.WhatsAppController` and the `:webhook` pipeline for
  all Meta inbound ingress; do not add parallel webhook routes.
- `WebhookVerifier`, `InboundNormalizer`, `Dedupe`, `SessionStore`, and
  `InboundCheckpoint` as the inbound boundary stack.
- `MessageCommand` as the internal inbound representation between controller
  and worker layers.
- Extend `FastCheck.Workers.WhatsAppInboundWorker` for VS-18 menu handling
  after dedupe/checkpoint/session steps — do not create a second inbound worker.
- `FastCheck.Sales.Conversation` checkpoint actions and `SessionStore` key
  helpers for durable + hot state coordination.
- `test/support/whatsapp_webhook_test_support.ex` for signed webhook fixtures.
- VS-16 `Client`/`MessageBuilder` for outbound replies in later slices only.

**Do not:**

- Bypass signature verification or raw-body retention for WhatsApp POSTs.
- Put full phone, `wa_id`, message body, raw payload, or secrets into Oban args,
  Redis session hashes, or logs.
- Recreate dedupe/session/checkpoint modules under a different namespace.
- Add checkout, Paystack, ticket issuance, or `DeliveryAttempt` logic into VS-17
  modules.
- Add migrations or change `sales_conversations` schema without an explicit
  slice that owns it.
- Couple VS-16 outbound provider modules to Redis, Oban, or Ash (boundary test
  still guards this).

**Authoritative tests to keep green:**

- `test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs`
- `test/fastcheck/messaging/whatsapp/`
- `test/fastcheck/workers/whatsapp_inbound_worker_test.exs`
- `test/fastcheck/sales/conversation_resource_skeleton_test.exs`
- `test/fastcheck/sales/vs_01e_boundary_test.exs`
- full `mix precommit` before merge

## Next Slice

Recommended next slice:  
VS-18 — WhatsApp Number-Only Conversation Flow

Entry condition:

- VS-17 merged on `main` with webhook ingress, dedupe, Redis session,
  `Conversation` checkpointing, and no-op inbound worker tests green.
- VS-05 checkout core and VS-16 outbound client remain unchanged contracts.
- VS-18 may extend `WhatsAppInboundWorker` and `Conversation.state` for
  Afrikaans-first number-only menus; it must still use approved Sales facades,
  not call Paystack directly from the WhatsApp flow, and not mutate Redis
  inventory or issue tickets.
