# FastCheck Sales Feature Planning Pack — VS-16 Meta Cloud API Outbound Client

**Pack ID:** `0037_VS-16_meta-cloud-api-outbound-client`  
**Slice:** `VS-16`  
**Slice name:** Meta Cloud API Outbound Client  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** Implementation-ready provider-boundary slice  
**Primary area:** WhatsApp / Meta Cloud API / Provider Boundary / Message Builder  
**Repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0037_VS-16_meta-cloud-api-outbound-client/`  
**Source docs:** `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md`, `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md`  
**Normalization:** Batch `0035_0037`, normalized 2026-06-14  
**Depends on:** VS-00B, VS-21A, VS-01F  
**Blocks:** VS-17, VS-18, VS-19, VS-20, VS-23C  

---

## 1. Purpose

Create the **outbound Meta Cloud API provider boundary** for WhatsApp messages.

This slice must only implement the safe, testable outbound HTTP client and message builder foundation:

```text
FastCheck.Messaging.WhatsApp.Client
FastCheck.Messaging.WhatsApp.Config
FastCheck.Messaging.WhatsApp.MessageBuilder
FastCheck.Messaging.WhatsApp.TemplateCatalog
```

It must not implement inbound webhooks, conversation state, checkout, payment-link handoff, ticket delivery workflows, or Meta 24-hour delivery-window orchestration yet.

Critical rule:

```text
WhatsApp is an interface layer.
WhatsApp must never become payment authority, ticket authority, inventory authority, or scanner-validity authority.
```

---

## 2. FastCheckin Current-State Findings

The implementation must follow existing FastCheckin patterns:

```text
App root: FastCheck
HTTP client pattern: Req-based modules, currently visible in FastCheck.TickeraClient
Runtime secret pattern: config/runtime.exs reads env vars and validates production secrets
Router protection pattern: browser/api/mobile pipelines already exist, but VS-16 does not add inbound routes
Logging policy: logger metadata is configured centrally; avoid adding sensitive values to metadata
Oban exists, but VS-16 does not need delivery workers yet
```

Existing `FastCheck.TickeraClient` gives the style to copy conceptually:

```text
plain module provider client
Req-based request boundary
timeout configuration
structured error tuples
safe logging of status categories instead of raw secrets/payloads
request function override for tests
```

Do not reuse Tickera-specific naming or API assumptions.

---

## 3. Ultimate Outcome

After VS-16:

```text
FastCheck can build and send outbound WhatsApp text/template messages through Meta Cloud API in tests/sandbox.
Provider credentials are read from runtime config, not committed.
Outbound calls have safe timeout, retry, and error classification behavior.
Logs do not expose access tokens, phone numbers, full payloads, or ticket URLs.
Message payload construction is testable without HTTP.
Provider responses are normalized for later DeliveryAttempt processing.
No business workflow sends customer tickets yet.
```

---

## 4. Scope

### In scope

```text
Add runtime config for Meta Graph API base URL, phone number ID, access token, app secret if needed later, and API version.
Add outbound client module with send_text/3 and send_template/4 or equivalent.
Add message builder for Afrikaans-first plain text and approved template payloads.
Add template catalog module for stable template names and language codes.
Add response normalizer for success, rate limit, auth failure, validation failure, server error, timeout, and transport error.
Add request-function injection for tests.
Add no-secret/no-PII logging tests.
Add provider-boundary unit tests using fake request function, not real Meta API.
```

### Out of scope

```text
No inbound webhook verification.
No WhatsApp conversation state machine.
No Redis session state.
No customer checkout flow.
No Paystack link handoff.
No ticket sending workflow.
No DeliveryAttempt creation.
No Oban delivery worker.
No secure ticket token generation.
No Meta template management UI.
No broad admin UI.
No database migrations unless config audit storage is explicitly already planned.
```

---

## 5. Recommended Files

```text
lib/fastcheck/messaging/whatsapp/config.ex
lib/fastcheck/messaging/whatsapp/client.ex
lib/fastcheck/messaging/whatsapp/message_builder.ex
lib/fastcheck/messaging/whatsapp/template_catalog.ex
lib/fastcheck/messaging/whatsapp/response.ex

config/runtime.exs
config/config.exs

test/fastcheck/messaging/whatsapp/config_test.exs
test/fastcheck/messaging/whatsapp/client_test.exs
test/fastcheck/messaging/whatsapp/message_builder_test.exs
test/fastcheck/messaging/whatsapp/template_catalog_test.exs
test/fastcheck/messaging/whatsapp/log_redaction_test.exs
```

Do not add `FastCheckWeb` routes in this slice.

---

## 6. Runtime Configuration Contract

Add configuration through environment variables in `config/runtime.exs`.

Recommended variables:

```text
META_GRAPH_API_BASE_URL=https://graph.facebook.com
META_GRAPH_API_VERSION=v20.0 or approved current version
META_WHATSAPP_PHONE_NUMBER_ID=...
META_WHATSAPP_ACCESS_TOKEN=...
META_WHATSAPP_APP_SECRET=...       # may be required later for webhook verification; can be optional in VS-16
META_WHATSAPP_REQUEST_TIMEOUT_MS=5000
META_WHATSAPP_RECEIVE_TIMEOUT_MS=10000
META_WHATSAPP_SANDBOX_MODE=true|false
```

Rules:

```text
Production must fail fast if phone number ID or access token is missing and WhatsApp outbound is enabled.
Dev/test may use fake values.
Never log the access token.
Never bake credentials into compile-time config.
Use runtime config so releases can rotate credentials without recompilation.
```

Recommended config module:

```text
FastCheck.Messaging.WhatsApp.Config.get!()
FastCheck.Messaging.WhatsApp.Config.enabled?()
FastCheck.Messaging.WhatsApp.Config.redacted_summary()
```

---

## 7. Client API Contract

Preferred module:

```text
FastCheck.Messaging.WhatsApp.Client
```

Required functions:

```text
send_text(to_e164, body, opts \\ [])
send_template(to_e164, template_name, language_code, components \\ [], opts \\ [])
```

Optional internal helpers:

```text
build_url(config)
build_headers(config)
request(method, url, opts)
normalize_response(response)
redact_for_log(payload_or_error)
```

Return shape:

```text
{:ok, %FastCheck.Messaging.WhatsApp.Response{
  provider: :meta,
  provider_message_id: binary | nil,
  status: :accepted,
  raw_status: integer,
  provider_status: binary | nil,
  retryable?: false,
  rate_limited?: false
}}

{:error, %FastCheck.Messaging.WhatsApp.Response{
  provider: :meta,
  status: :auth_error | :rate_limited | :validation_error | :server_error | :timeout | :transport_error | :unknown_error,
  raw_status: integer | nil,
  provider_error_code: binary | nil,
  provider_error_message: redacted_binary | nil,
  retryable?: boolean,
  rate_limited?: boolean
}}
```

Rules:

```text
Do not return raw response payload by default.
If raw response retention is needed later, it belongs in DeliveryAttempt/Payment-like audit policy, not client logs.
Do not hide provider failures as success.
Rate-limit and 5xx errors must be retryable.
Auth errors must not be blindly retried forever.
Validation errors must include safe diagnostic code/message only.
```

---

## 8. Message Builder Contract

Preferred module:

```text
FastCheck.Messaging.WhatsApp.MessageBuilder
```

Required builders:

```text
text_message(to_e164, body)
template_message(to_e164, template_name, language_code, components)
```

Validation rules:

```text
to_e164 must be normalized E.164-like string or fail validation.
body must be non-empty and bounded.
template_name must come from TemplateCatalog for production paths.
language_code must be explicit, e.g. af or en_US depending approved templates.
components must be bounded and must not contain raw tokens/secrets.
```

Do not include a secure ticket URL in test examples unless it is a fake redacted URL.

---

## 9. Template Catalog Contract

Preferred module:

```text
FastCheck.Messaging.WhatsApp.TemplateCatalog
```

Initial template keys:

```text
:ticket_ready_af
:ticket_ready_en
:payment_pending_af
:payment_pending_en
:payment_link_af
:payment_link_en
:delivery_fallback_af
:delivery_fallback_en
```

Rules:

```text
TemplateCatalog stores approved template names and language codes only.
It must not contain access tokens.
It must not send messages.
Template existence tests must be pure unit tests.
Real template approval/runbook details belong to VS-20/VS-23C.
```

---

## 10. HTTP and Retry Rules

Use `Req` consistently with existing FastCheckin style.

Recommended request options:

```text
connect_timeout: configured connect/request timeout
receive_timeout: configured receive timeout
headers: authorization bearer token, content-type application/json
json: payload
```

Rules:

```text
Do not implement uncontrolled automatic retries inside the client if later Oban workers will own retry strategy.
A tiny retry for transient transport setup may be acceptable only if tests prove idempotent behavior.
Return retryable? metadata so VS-20 workers can decide retry/fallback.
Use request-function injection for tests.
Do not make network calls in unit tests.
```

---

## 11. Security and PII Rules

Do not log:

```text
access token
authorization header
full recipient phone number
message body if it can contain PII or ticket links
secure ticket URL
delivery token
QR token
raw provider response payload
```

Allowed log metadata:

```text
provider: meta
operation: send_text/send_template
status class
http status
provider error code
retryable?
correlation_id
recipient_hash or last4 only if policy allows
```

Redaction helper required:

```text
FastCheck.Messaging.WhatsApp.Client.redact_error/1
```

or equivalent private helper with tests.

---

## 12. Performance and Scaling Review

### Data placement

```text
Hot: none in this slice.
Warm: no Redis cache in this slice.
Cold: no new DB tables in this slice.
External: Meta Cloud API over HTTP.
```

### Concurrency

```text
Client must be stateless.
Do not create GenServer bottleneck.
Do not block LiveViews/controllers on delivery workflows in future slices.
Outbound delivery from business flows must happen via Oban in VS-19/VS-20.
```

### Rate limiting

```text
VS-16 only classifies 429/rate-limit responses.
Do not implement global send-rate limiter here unless a small provider-boundary throttle is explicitly required.
VS-20 owns delivery window/fallback orchestration.
VS-17 owns inbound rate limiting.
```

### Cache / Redis / PubSub

```text
No Redis structures.
No PubSub broadcasts.
No Cachex/ETS invalidation.
No DB indexes.
```

---

## 13. RED/GREEN Test Plan

### RED tests first

```text
RED: config fails in prod/outbound-enabled mode when access token missing.
RED: config redacted_summary never includes access token.
RED: send_text builds correct Meta endpoint with phone number ID.
RED: send_text sets Authorization bearer header without logging token.
RED: send_text normalizes 2xx response into accepted response with provider_message_id.
RED: send_template builds template payload with explicit language code and components.
RED: 401/403 returns auth_error and retryable? false.
RED: 429 returns rate_limited and retryable? true.
RED: 400 returns validation_error and retryable? false.
RED: 5xx returns server_error and retryable? true.
RED: Req transport error returns transport_error and retryable? true.
RED: timeout returns timeout and retryable? true.
RED: invalid phone/body/template input fails before HTTP call.
RED: logs do not include access token, authorization header, full phone, body, or token-like URL.
RED: no DeliveryAttempt, Order, PaymentAttempt, TicketIssue, Attendee, Redis, or Oban behavior is called.
```

### GREEN targets

```text
GREEN: Provider boundary sends outbound Meta API payloads through a fake request function in tests.
GREEN: All responses are normalized and safe for future DeliveryAttempt persistence.
GREEN: No secrets or PII leak into logs.
GREEN: Client is stateless and workflow-free.
GREEN: VS-17/VS-19/VS-20 can build on the client without changing its public contract.
```

---

## 14. Failure Modes

| Failure | Required behavior |
|---|---|
| Missing token in production | Fail fast if outbound enabled. |
| Invalid phone number | Return validation error before HTTP. |
| Empty message body | Return validation error before HTTP. |
| Meta auth failure | Return `auth_error`, non-retryable. |
| Meta rate limit | Return `rate_limited`, retryable. |
| Meta 5xx | Return `server_error`, retryable. |
| Transport timeout | Return `timeout`, retryable. |
| Unknown response shape | Return safe `unknown_error`; do not leak raw payload. |
| Logs contain token/phone/body | Tests fail. |

---

## 15. Observability

Telemetry names:

```text
[:fastcheck, :whatsapp, :outbound, :send_started]
[:fastcheck, :whatsapp, :outbound, :send_succeeded]
[:fastcheck, :whatsapp, :outbound, :send_failed]
[:fastcheck, :whatsapp, :outbound, :rate_limited]
```

Required measurements:

```text
duration_ms
```

Allowed metadata:

```text
provider: :meta
message_type: :text | :template
status: normalized_status
http_status: integer | nil
retryable?: boolean
correlation_id
```

Forbidden metadata:

```text
phone_e164
access_token
authorization header
message body
secure ticket URL
provider raw payload
```

---

## 16. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-16 Meta Cloud API Outbound Client in `JCSchoeman96/FastCheckin`. |
| Objective | Add a safe outbound WhatsApp provider boundary that can send Meta Cloud API text/template messages and normalize provider responses without owning checkout, payment, ticket issuing, delivery audit, or conversation state. |
| Output | `lib/fastcheck/messaging/whatsapp/config.ex`, `client.ex`, `message_builder.ex`, `template_catalog.ex`, `response.ex`; runtime config entries; unit tests for config, payloads, response normalization, error classification, and log redaction. |
| Note | Follow FastCheckin’s existing plain-module `Req` client style from `FastCheck.TickeraClient`; use request-function injection for tests and no real network calls. Runtime secrets must come from `config/runtime.exs`; never compile or log Meta access tokens. Data layer: no hot/warm/cold DB writes; no Redis; no Cachex/ETS; no PubSub; no Oban. This is provider-boundary only. Classify 2xx, 400, 401/403, 429, 5xx, timeout, and transport errors. Return normalized responses safe for later DeliveryAttempt. No DeliveryAttempt creation, no WhatsApp webhook, no Redis session, no checkout, no Paystack, no TicketIssue, no Attendee mutation, no admin UI. Logs/telemetry must not include phone_e164, message body, auth header, access token, ticket URL, delivery token, QR token, or raw provider payload. |
| Success | Tests prove the client builds correct Meta payloads, handles provider failures safely, leaks no secrets/PII, and remains a stateless boundary ready for VS-17/VS-19/VS-20. |

---

## 17. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-16 — Meta Cloud API Outbound Client in JCSchoeman96/FastCheckin.

Implement only the outbound WhatsApp provider boundary.

Create:
- lib/fastcheck/messaging/whatsapp/config.ex
- lib/fastcheck/messaging/whatsapp/client.ex
- lib/fastcheck/messaging/whatsapp/message_builder.ex
- lib/fastcheck/messaging/whatsapp/template_catalog.ex
- lib/fastcheck/messaging/whatsapp/response.ex

Follow existing FastCheckin plain-module Req client style from FastCheck.TickeraClient.
Use runtime config from config/runtime.exs.
Use request-function injection for tests.
Do not make real network calls in tests.

Public client functions:
- send_text(to_e164, body, opts \\ [])
- send_template(to_e164, template_name, language_code, components \\ [], opts \\ [])

Required behavior:
- build Meta Graph API messages endpoint using phone_number_id
- set Authorization bearer header
- build text and template payloads
- normalize 2xx accepted response
- classify 400, 401/403, 429, 5xx, timeout, and transport errors
- return retryable? metadata
- redact logs and telemetry

Do not implement:
- inbound WhatsApp webhook
- Redis session state
- conversation menus
- checkout or Paystack link handoff
- DeliveryAttempt creation
- ticket delivery workflow
- Oban worker
- TicketIssue/Attendee mutation
- admin UI

Tests must prove:
- missing production credentials fail when outbound is enabled
- redacted config summary hides access token
- payloads are correct
- all error classes normalize correctly
- invalid phone/body/template fails before HTTP
- no logs include access token, auth header, full phone, message body, ticket URL, delivery token, QR token, or raw provider payload
- no Sales/Payment/Ticket/Attendee/Redis/Oban behavior is called
```

---

## 18. Human Review Checklist

```text
[ ] Files are under FastCheck.Messaging.WhatsApp namespace.
[ ] Runtime env config is used; no secrets in compile-time config.
[ ] Access token is never logged.
[ ] Full phone/body/ticket URLs are not logged.
[ ] Request function injection exists for tests.
[ ] Unit tests do not hit Meta API.
[ ] 2xx, 400, 401/403, 429, 5xx, timeout, transport error are classified.
[ ] 429/5xx/timeout/transport errors are retryable.
[ ] Auth/validation errors are not blindly retryable.
[ ] No DeliveryAttempt rows are created.
[ ] No inbound webhook routes are added.
[ ] No Redis/session/conversation/checkout/payment/ticket issuance behavior is added.
[ ] Telemetry metadata is PII-safe.
```

---

## 19. Next Slice

```text
VS-17 — Meta Inbound Webhook and Session State
```
