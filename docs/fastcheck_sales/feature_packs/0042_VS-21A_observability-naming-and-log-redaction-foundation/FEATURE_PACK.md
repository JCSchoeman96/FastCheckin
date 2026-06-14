# FastCheck Sales Feature Planning Pack — VS-21A Observability Naming and Log Redaction Foundation

**Pack ID:** `0042_VS-21A_observability-naming-and-log-redaction-foundation`  
**Slice:** `VS-21A`  
**Slice name:** Observability Naming and Log Redaction Foundation  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** Implementation-ready foundation slice  
**Primary area:** Observability / Security / Telemetry / Logging  
**Repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0042_VS-21A_observability-naming-and-log-redaction-foundation/`  
**Source docs:** `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md`, `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md`  
**Depends on:** VS-00, VS-00B  
**Alignment note:** Acceptance requires alignment with VS-00B security/PII/log-redaction decisions.  
**Blocks:** VS-21B, VS-22, VS-23B, VS-23C, production launch hardening  

---

## 1. Purpose

Create the shared observability and redaction foundation for FastCheck Sales before the final operational metrics, launch tests, and runbooks.

This slice does **not** build dashboards or analytics tables. It reserves names, helpers, metadata rules, redaction rules, and test contracts so later Sales, Paystack, WhatsApp, ticketing, delivery, revocation, and admin slices emit consistent, safe telemetry.

Core rule:

```text
Observability must help operations without leaking PII, tokens, provider secrets, payment links, QR payloads, or raw provider payloads.
```

---

## 2. FastCheckin Current-State Findings

Use the current FastCheckin style:

```text
FastCheckWeb.Plugs.LoggerMetadata already sets request metadata such as request/user/event/device/IP context.
config/config.exs already enumerates Logger metadata keys.
FastCheckWeb.SentryFilter already redacts obvious sensitive request/extra fields for Sentry.
runtime.exs configures Sentry with FastCheckWeb.SentryFilter when SENTRY_DSN is present.
```

VS-21A should extend and harden those existing conventions rather than inventing a parallel logging stack.

---

## 3. Ultimate Outcome

After this slice:

```text
Sales telemetry names are stable.
Sales Logger metadata keys are approved.
A reusable redaction helper exists.
Sentry filtering covers Sales, Paystack, WhatsApp, ticket tokens, QR payloads, delivery links, and raw provider payloads.
Every later slice can emit telemetry without naming drift.
Tests prove sensitive fields are redacted before logs/events leave the process.
```

---

## 4. Scope

### In scope

```text
Define telemetry event namespace and naming rules.
Add a shared redaction helper for Sales/Payments/WhatsApp/Tickets.
Extend Sentry filter coverage for Sales-sensitive fields.
Define allowed Logger metadata keys.
Define correlation_id/idempotency_key/request_id propagation rules.
Add tests for redaction and event naming.
Document forbidden metadata and payload fields.
Add small helper modules only; no dashboards yet.
```

### Out of scope

```text
No analytics dashboard.
No materialized views.
No Prometheus exporter changes unless a tiny naming assertion is already required.
No business workflow implementation.
No Paystack/Meta HTTP behavior.
No TicketIssue, Attendee, DeliveryAttempt, or scanner mutations.
No raw payload retention implementation.
No production alert routing.
```

---

## 5. Recommended Files

Add or extend:

```text
lib/fastcheck/observability.ex
lib/fastcheck/observability/redactor.ex
lib/fastcheck/observability/telemetry_names.ex
lib/fastcheck/observability/correlation.ex
lib/fastcheck_web/sentry_filter.ex
config/config.exs

test/fastcheck/observability/redactor_test.exs
test/fastcheck/observability/telemetry_names_test.exs
test/fastcheck/observability/correlation_test.exs
test/fastcheck_web/sentry_filter_test.exs
```

Avoid scattering redaction logic across Paystack, WhatsApp, ticketing, and admin modules.

---

## 6. Telemetry Naming Contract

Use stable lists/functions rather than ad-hoc strings.

Recommended module:

```text
FastCheck.Observability.TelemetryNames
```

Required event groups:

```text
[:fastcheck, :sales, :checkout, :reserved]
[:fastcheck, :sales, :checkout, :expired]
[:fastcheck, :sales, :checkout, :released]
[:fastcheck, :sales, :inventory, :reserved]
[:fastcheck, :sales, :inventory, :consumed]
[:fastcheck, :sales, :inventory, :released]
[:fastcheck, :sales, :inventory, :reconciled]
[:fastcheck, :sales, :payment, :initialized]
[:fastcheck, :sales, :payment, :webhook_received]
[:fastcheck, :sales, :payment, :verified]
[:fastcheck, :sales, :payment, :mismatch]
[:fastcheck, :sales, :payment, :failed]
[:fastcheck, :sales, :ticket, :issued]
[:fastcheck, :sales, :ticket, :issue_failed]
[:fastcheck, :sales, :ticket, :revoked]
[:fastcheck, :sales, :scanner_visibility, :sync_queued]
[:fastcheck, :sales, :delivery, :queued]
[:fastcheck, :sales, :delivery, :sent]
[:fastcheck, :sales, :delivery, :failed]
[:fastcheck, :sales, :whatsapp, :inbound_received]
[:fastcheck, :sales, :whatsapp, :outbound_sent]
[:fastcheck, :sales, :manual_review, :opened]
[:fastcheck, :sales, :manual_review, :closed]
```

Rules:

```text
Use list-style Telemetry event names.
Never build telemetry names from user input.
Never include buyer_phone, buyer_email, raw payload, message body, token, or payment URL in measurements or metadata.
Metadata should contain IDs, status/reason codes, channel/provider enums, and redacted references only.
```

---

## 7. Logger Metadata Contract

Approved metadata keys for Sales work:

```text
:request_id
:correlation_id
:idempotency_key
:actor_type
:actor_id
:event_id
:order_id
:order_public_reference
:checkout_session_id
:payment_attempt_id
:payment_event_id
:ticket_issue_id
:delivery_attempt_id
:conversation_id
:provider
:provider_reference_redacted
:channel
:status
:reason_code
:source
:worker
:queue
:attempt
:duration_ms
:result
:error_code
```

Forbidden metadata keys:

```text
:buyer_email
:buyer_phone
:phone_e164
:recipient
:authorization_url
:access_code
:delivery_token
:delivery_token_hash
:qr_token
:qr_token_hash
:raw_payload
:raw_verify_response
:raw_initialize_response
:message_body
:wa_message_body
:meta_access_token
:paystack_secret_key
```

If a later slice needs one of these values for debugging, it must use a purpose-built redacted derivative such as:

```text
:buyer_phone_last4
:buyer_email_domain
:provider_reference_redacted
:ticket_code_redacted
```

---

## 8. Redaction Helper Contract

Recommended module:

```text
FastCheck.Observability.Redactor
```

Required functions:

```text
redact_map(map)
redact_keyword(keyword)
redact_value(key, value)
redact_phone(phone)
redact_email(email)
redact_token(token_or_hash)
redact_url(url)
redact_ticket_code(ticket_code)
safe_metadata(map_or_keyword)
```

Minimum behavior:

```text
phone: keep country prefix if safe + last 2/4 digits only, otherwise [FILTERED_PHONE]
email: keep domain only or j***@domain style, never full email
URL: remove query params and sensitive path tokens
provider reference: keep short suffix only
access_code/authorization_url/tokens/hashes/raw payloads: [FILTERED]
message bodies: [FILTERED_MESSAGE]
unknown nested maps/lists: recursively redact sensitive keys
```

Do not over-engineer. Use deterministic pure functions and simple key matching.

---

## 9. Correlation and Idempotency Rules

Recommended module:

```text
FastCheck.Observability.Correlation
```

Rules:

```text
Controllers should use request_id as the entry correlation source when no correlation_id exists.
Workers should persist and reuse correlation_id/idempotency_key from the originating state transition or job args.
Provider boundaries should include correlation_id in internal metadata but not send it to external providers unless explicitly safe.
Oban jobs should log correlation_id, worker, queue, attempt, and entity IDs.
Manual review actions should include actor_type, actor_id, reason_code, and correlation_id.
```

Avoid:

```text
Do not use buyer phone/email as idempotency keys.
Do not generate a new correlation_id at every layer if one already exists.
Do not log full Oban args if they contain tokens or payloads.
```

---

## 10. Sentry Filter Hardening

Extend current `FastCheckWeb.SentryFilter` so it catches Sales-specific sensitive fields.

Add sensitive key patterns:

```text
buyer_phone
buyer_email
phone_e164
recipient
authorization_url
access_code
delivery_token
delivery_token_hash
qr_token
qr_token_hash
raw_payload
raw_verify_response
raw_initialize_response
provider_payload
message_body
wa_message_body
meta_access_token
paystack_secret
paystack_secret_key
whatsapp_verify_token
app_secret
```

Rules:

```text
Request body, request headers, query params, and extra metadata must be filtered.
Filter nested maps/lists recursively.
Do not filter useful non-sensitive IDs such as order_id, ticket_issue_id, payment_attempt_id.
Do not send raw Paystack/Meta payloads to Sentry by default.
```

---

## 11. RED/GREEN Test Plan

### RED tests first

```text
RED: Redactor removes delivery_token and delivery_token_hash.
RED: Redactor removes qr_token and qr_token_hash.
RED: Redactor removes Paystack authorization_url and access_code.
RED: Redactor removes Meta access token and app secret.
RED: Redactor masks buyer_phone and buyer_email.
RED: Redactor recursively filters nested raw provider payloads.
RED: safe_metadata rejects/filters forbidden metadata keys.
RED: TelemetryNames exposes every approved Sales event and no ad-hoc strings.
RED: SentryFilter filters Sales-sensitive request data.
RED: SentryFilter filters Sales-sensitive headers.
RED: SentryFilter filters nested extra data.
RED: correlation helper preserves existing request_id/correlation_id.
RED: logs do not include raw WhatsApp message body, secure ticket URL token, Paystack URL, or raw payload.
```

### GREEN targets

```text
GREEN: One shared redaction helper is used by provider/client/worker/logging code.
GREEN: Sentry payloads are safe for Sales/Payment/WhatsApp/Ticket failures.
GREEN: Telemetry names are stable and documented.
GREEN: Later VS-21B can build dashboards and metrics without renaming churn.
```

---

## 12. Performance and Scaling Review

```text
Hot data: Logger metadata and telemetry metadata only; must be small maps/lists.
Warm data: None.
Cold data: No database writes in this slice.
Redis: None.
Oban: No new workers; only conventions for worker metadata.
Performance target: redaction helpers must be pure and lightweight; avoid huge payload traversal in hot loops except when filtering errors/events.
```

Rules:

```text
Do not attach large raw payloads to telemetry metadata.
Do not attach whole structs to logs.
Do not run expensive JSON encoding just for log lines.
Do not log per-ticket events in massive bulk operations without sampling or summary counts.
```

---

## 13. Security Review

Required:

```text
No raw provider payloads in logs by default.
No ticket delivery tokens or token hashes in logs.
No QR payloads in logs.
No WhatsApp message bodies in logs.
No Paystack authorization URLs or access codes in logs.
No customer phone/email in Logger metadata.
```

Allowed:

```text
order_id
public_reference if opaque and non-sequential
payment_attempt_id
payment_event_id
ticket_issue_id
delivery_attempt_id
conversation_id
status/reason codes
provider enum
channel enum
redacted provider reference
redacted ticket code
```

---

## 14. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-21A Observability Naming and Log Redaction Foundation in `JCSchoeman96/FastCheckin`. |
| Objective | Establish shared telemetry names, correlation rules, Logger metadata policy, and redaction helpers so all Sales, Paystack, WhatsApp, ticketing, delivery, revocation, and admin slices can be observed safely without leaking PII, provider secrets, payment URLs, QR payloads, or ticket tokens. |
| Output | Add `lib/fastcheck/observability.ex`, `lib/fastcheck/observability/redactor.ex`, `lib/fastcheck/observability/telemetry_names.ex`, `lib/fastcheck/observability/correlation.ex`; harden `lib/fastcheck_web/sentry_filter.ex`; update `config/config.exs` Logger metadata list only with approved safe keys; add tests under `test/fastcheck/observability/` and `test/fastcheck_web/sentry_filter_test.exs`. |
| Note | Use FastCheckin’s existing `FastCheckWeb.Plugs.LoggerMetadata`, Logger metadata config, runtime Sentry setup, and `FastCheckWeb.SentryFilter`. Keep helpers pure and small. Do not add dashboards, DB tables, workers, provider HTTP, payment logic, ticket logic, delivery logic, or scanner/mobile changes. Required telemetry groups include checkout, inventory, payment, ticket, scanner_visibility, delivery, whatsapp, and manual_review. Forbidden log/metadata fields: buyer email/phone, phone_e164, recipient, Paystack authorization_url/access_code, delivery_token/hash, qr_token/hash, raw_payload/raw provider responses, WhatsApp message body, Meta/Paystack secrets. Cache/TTL/Redis: none in this slice. PubSub: none. Indexes: none. Performance: never attach full structs or raw payloads to telemetry/logs; keep metadata bounded. |
| Success | Redaction tests prove Sales-sensitive values are filtered recursively; telemetry names are stable; correlation/idempotency conventions are documented in code; Sentry filter no longer leaks Sales/Paystack/WhatsApp/ticket secrets; later slices can emit safe observability without naming drift. |

---

## 15. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-21A — Observability Naming and Log Redaction Foundation in JCSchoeman96/FastCheckin.

Use current FastCheckin conventions:
- `FastCheckWeb.Plugs.LoggerMetadata` already sets request metadata.
- `config/config.exs` already configures Logger metadata keys.
- `FastCheckWeb.SentryFilter` already filters obvious sensitive fields.
- Runtime config already wires Sentry to `FastCheckWeb.SentryFilter` when enabled.

Implement:
1. `FastCheck.Observability.Redactor` with pure redaction helpers.
2. `FastCheck.Observability.TelemetryNames` with approved Sales telemetry event lists/functions.
3. `FastCheck.Observability.Correlation` for request/correlation/idempotency helper rules.
4. Harden `FastCheckWeb.SentryFilter` to recursively filter Sales/Paystack/WhatsApp/ticket sensitive fields.
5. Update Logger metadata config with only approved safe Sales keys.
6. Add tests for redaction, telemetry naming, correlation preservation, and Sentry filtering.

Do not:
- add dashboards
- add DB tables or migrations
- add provider HTTP behavior
- add Paystack/Meta/Ticket/Attendee/DeliveryAttempt/scanner behavior
- log raw provider payloads
- log WhatsApp message bodies
- log Paystack authorization URLs/access codes
- log delivery tokens or token hashes
- log QR tokens or QR payloads
- use buyer phone/email as metadata or idempotency keys

Success:
All tests prove safe bounded observability and later slices can emit telemetry/logs without leaking PII or secrets.
```

---

## 16. Human Review Checklist

```text
[ ] FastCheckin existing LoggerMetadata pattern is reused.
[ ] FastCheckWeb.SentryFilter is hardened, not replaced with a parallel filter.
[ ] Redactor handles nested maps/lists.
[ ] Redactor filters tokens, hashes, Paystack URLs/access codes, raw payloads, and WhatsApp message bodies.
[ ] Phone/email are masked, not logged raw.
[ ] Logger metadata config includes only approved safe keys.
[ ] Telemetry names are stable list-style names.
[ ] No raw user input is used to construct telemetry event names.
[ ] Correlation/idempotency helper preserves existing IDs.
[ ] No DB/migration/provider/business/scanner behavior was added.
[ ] Tests cover recursive Sentry filtering.
[ ] Tests cover forbidden metadata keys.
```

---

## 17. Next Slice

```text
VS-21B — Operational Metrics and Audit Views
```
