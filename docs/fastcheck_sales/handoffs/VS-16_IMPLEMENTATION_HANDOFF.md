# VS-16 Implementation Handoff

## Status

Merged.

PR: #398 — feat(whatsapp): add Meta outbound provider boundary  
Merge commit: `df181b9a6c403dbff9bb950347f6a1ebda6c28bf`  
Merged at: 2026-06-26T07:23:21Z  
Branch: `vs-16-meta-cloud-api-outbound-client`

## What Changed

VS-16 added a plain Meta WhatsApp outbound provider boundary under
`FastCheck.Messaging.WhatsApp` for runtime config, payload building, template
catalog lookup, normalized responses, and outbound Meta Cloud API calls through
`Req`.

WhatsApp outbound is disabled by default (`META_WHATSAPP_ENABLED=false`). When
enabled, boot and call paths fail fast on missing required Meta config. Tests
inject HTTP via `:whatsapp_request_fun`. Historical Sales boundary guards were
narrowly updated to allow the approved WhatsApp namespace while preserving
route/worker/workflow guards.

## Files Changed

- `lib/fastcheck/messaging/whatsapp/config.ex` — enabled-gated config load/validation;
  safe Inspect and `redacted_summary/0` for secrets.
- `lib/fastcheck/messaging/whatsapp/client.ex` — `send_text/3` and `send_template/4`;
  Req execution with `decode_body: false` and manual binary JSON decode; status
  classification; safe logging via `Redactor` and `Correlation`.
- `lib/fastcheck/messaging/whatsapp/message_builder.ex` — pure text/template payload
  construction; `+E164` input normalized to Meta `to` without leading `+`.
- `lib/fastcheck/messaging/whatsapp/template_catalog.ex` — stable approved template
  keys, names, and language codes for Afrikaans/English sales templates.
- `lib/fastcheck/messaging/whatsapp/response.ex` — normalized provider response
  struct; safe Inspect for error messages.
- `config/config.exs` — WhatsApp defaults off; injectable `:whatsapp_request_fun`.
- `config/runtime.exs` — env-driven Meta WhatsApp config; prod fail-fast when
  enabled and required secrets are missing.
- `test/fastcheck/messaging/whatsapp/boundary_test.exs` — namespace exists; no
  Sales/Ash/Repo/Redis/Oban/web/scanner coupling; no webhook routes or workers.
- `test/fastcheck/messaging/whatsapp/client_test.exs` — request injection, endpoint
  shape, binary JSON 2xx/error bodies, status normalization.
- `test/fastcheck/messaging/whatsapp/config_test.exs` — disabled boot safety,
  enabled call validation, secret redaction.
- `test/fastcheck/messaging/whatsapp/log_redaction_test.exs` — logs do not expose
  tokens, phone numbers, or full payloads.
- `test/fastcheck/messaging/whatsapp/message_builder_test.exs` — phone/body/template
  validation before HTTP.
- `test/fastcheck/messaging/whatsapp/template_catalog_test.exs` — catalog keys and
  lookup behavior.
- Historical `test/fastcheck/sales/*_boundary_test.exs` — removed obsolete
  forbidden-path assertions for the WhatsApp namespace only.

## Contracts Now Available

- `FastCheck.Messaging.WhatsApp.Config.enabled?/0` and `get/0` read Application
  env; `validate_for_boot/0` passes when disabled; `validate_for_call/0` requires
  enabled plus graph API base URL/version, phone number ID, access token, and
  positive timeouts.
- `FastCheck.Messaging.WhatsApp.Client.send_text/3` and `send_template/4` are the
  only outbound HTTP entrypoints; tests inject via `:whatsapp_request_fun`.
- `FastCheck.Messaging.WhatsApp.MessageBuilder.text_message/2` and
  `template_message/4` build Meta payloads without HTTP; public phone input must
  be `+E164`; outbound JSON `to` omits the leading `+`.
- `FastCheck.Messaging.WhatsApp.TemplateCatalog.fetch/1` resolves stable template
  keys (`:ticket_ready_af`, `:payment_link_en`, etc.) to approved Meta names and
  language codes.
- `FastCheck.Messaging.WhatsApp.Response` is the normalized success/error shape
  with `status`, `provider_message_id`, `retryable?`, `rate_limited?`, and
  `safe_metadata`.
- Client error classification: `400` → `:validation_error`; `401`/`403` →
  `:auth_error`; `429` → `:rate_limited` (retryable); `5xx` → `:server_error`
  (retryable); transport/timeout → retryable transport errors.
- WhatsApp modules do not reference Ash, Sales resources, Repo, Redis, Oban, web
  surfaces, or Payments (enforced by boundary test).

## Decisions Applied

- Provider boundary only; no Sales workflow, delivery, or conversation activation.
- `META_WHATSAPP_ENABLED=false` keeps boot safe without secrets; prod fail-fast
  only when enabled and required config is missing.
- Req via injectable `:whatsapp_request_fun`; no parallel HTTP client.
- Reuses VS-21A `Redactor` and `Correlation`; no ad-hoc redaction or new
  telemetry events in this slice.
- `decode_body: false` with manual binary JSON decode, matching the Paystack
  provider-boundary pattern.
- Afrikaans-first template catalog entries are local constants only; no Meta
  template management UI.
- `app_secret` is loaded for later inbound/webhook slices; not used for outbound
  calls in VS-16.
- No Redis session state, no inbound webhook verification, no `DeliveryAttempt`
  persistence in this slice.

## Boundaries Still Enforced

- No inbound Meta webhook route, signature verification, or session state.
- No WhatsApp conversation state machine or Redis hot session.
- No customer checkout flow, Paystack link handoff, or payment initialization.
- No ticket sending workflow, secure ticket links, or `DeliveryAttempt` creation.
- No Oban delivery workers.
- No database migrations or Ash resource changes.
- No scanner/mobile/Android changes.
- No admin/customer WhatsApp UI.
- No route/worker additions beyond the provider modules.

## Tests Added Or Updated

- `test/fastcheck/messaging/whatsapp/*` — 24 tests covering config, client,
  message builder, template catalog, redaction, binary JSON bodies, and namespace
  isolation.
- Historical `test/fastcheck/sales/core_resource_boundary_test.exs`,
  `ticket_offer_boundary_test.exs`, `vs_01d_boundary_test.exs`,
  `vs_01e_boundary_test.exs`, `vs_01f_boundary_test.exs`, and
  `vs_01g_index_and_migration_verification_test.exs` — updated allowlists only;
  no new Sales behavior.

## Verification Reported

From PR #398:

- `mix test test/fastcheck/messaging/whatsapp/` — 24 tests, 0 failures
- `mix test test/fastcheck/observability/ test/fastcheck/payments/paystack/ test/fastcheck/sales/vs_01f_boundary_test.exs test/fastcheck/sales/vs_01f_policy_test.exs test/fastcheck/sales/domain_shell_test.exs` — 74 tests, 0 failures
- `mix precommit` — 939 tests, 0 failures, 4 skipped

## Known Limitations

- Outbound client is available but not connected to delivery workflows,
  `DeliveryAttempt`, or conversation state.
- `TemplateCatalog` lists approved template names only; it does not register or
  sync templates with Meta.
- `send_text/3` can be used in tests/sandbox but no production workflow sends
  customer tickets yet.
- `app_secret` is configured but unused until VS-17 inbound webhook work.
- No retry orchestration, Oban workers, or delivery-window (24-hour) logic.

## Next Agent Guidance

**Reuse:**

- All modules under `lib/fastcheck/messaging/whatsapp/` as the sole Meta outbound
  HTTP and payload boundary.
- `Client.send_text/3` and `Client.send_template/4` from service/worker layers
  only, not from Ash resources or LiveViews directly.
- `MessageBuilder` for payload construction in tests without HTTP.
- `TemplateCatalog.fetch/1` for stable template key → Meta name/language mapping.
- `:whatsapp_request_fun` injection in tests instead of live Meta API calls.
- `FastCheck.Observability.Redactor` and `Correlation` for any new WhatsApp
  logging/metadata.

**Do not:**

- Add Meta outbound HTTP or payload logic outside `FastCheck.Messaging.WhatsApp.*`.
- Couple provider modules to `FastCheck.Sales.*` Ash resources or checkout flows.
- Log raw provider payloads, access tokens, phone numbers, or ticket URLs.
- Recreate parallel config, response, or template catalog modules.
- Add inbound webhook or Redis session logic into VS-16 modules; that belongs in
  VS-17.

**Authoritative tests to keep green:**

- `test/fastcheck/messaging/whatsapp/`
- `test/fastcheck/sales/*_boundary_test.exs` (especially VS-01F guards)
- full `mix precommit` before merge

## Next Slice

Recommended next slice:  
VS-17 — Meta Inbound Webhook and Session State

Entry condition:

- VS-16 merged on `main` with outbound provider modules and tests green.
- VS-00B security/token policy and VS-21A observability/redaction foundation
  remain unchanged contracts.
- VS-17 may add inbound webhook routes, signature verification, Redis session
  state, dedupe, and rate limiting; it still must not implement the number-only
  sales conversation flow, checkout, Paystack initialization, ticket issuance, or
  outbound ticket delivery workflows.
