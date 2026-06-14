# FastCheck Sales Feature Planning Pack — VS-00B Security, PII, and Token Policy Finalization

**Pack ID:** `0002_VS-00B_security-pii-and-token-policy-finalization`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0002_VS-00B_security-pii-and-token-policy-finalization/`  
**Slice:** `VS-00B`  
**Slice name:** Security, PII, and Token Policy Finalization  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Ready for planning after VS-00  
**Primary area:** Security / Docs / Ash Policy Planning  
**Depends on:** VS-00  
**Blocks:** VS-01A+, VS-01F, VS-05A, VS-06A–VS-06C, VS-07A–VS-07C, VS-08, VS-11, VS-12, VS-13, VS-16–VS-20, VS-21A  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack defines the security, PII, raw provider payload, token, log-redaction, and field-access policy for FastCheck Sales before any resource implementation, provider integration, admin UI, customer ticket page, or WhatsApp flow is built.

This is a planning and contract slice only. It must produce documentation precise enough that later coding agents cannot casually leak phone numbers, emails, provider payloads, access codes, plaintext tokens, or customer payment/ticket details.

Core product framing to preserve:

```text
FastCheck Sales is multi-channel, but WhatsApp is first.

Primary production customer channel:
  WhatsApp via Meta Cloud API

Secondary supported Sales paths:
  admin-assisted sales
  web checkout sales
  internal pilot sales

All channels must use the same Sales core:
  Redis inventory reservation
  Paystack server-side verification
  idempotent ticket issuance
  DeliveryAttempt audit
  scanner-safe revocation
```

Security principle:

```text
WhatsApp, web checkout, admin-assisted sales, and internal pilot flows are interfaces only.
No interface may bypass the shared security, token, payment, inventory, audit, or scanner-validity policies.
```

---

## 2. Ultimate Outcome

After VS-00B is complete, the project has accepted security contracts for:

```text
PII classification
Ash field-level access policy
admin/operator display masking
customer-facing token hashing, expiry, rotation, and revocation
raw Paystack/Meta provider payload access and retention
log redaction
secret/config handling
Paystack security handling
Meta/WhatsApp security handling
tenant/event access policy
security-focused RED/GREEN documentation tests
```

No implementation code should be written in this slice.

---

## 3. Scope

### In scope

```text
Define what is PII and sensitive payment/provider data.
Define admin vs operator vs system vs customer_session access rules.
Define Ash field-level policy expectations.
Define masked display rules for admin/operator surfaces.
Define customer-facing token requirements.
Define raw provider payload retention and access rules.
Define log-redaction rules.
Define cache/key safety rules.
Define tenant/event access rules.
Define security acceptance criteria for future slices.
Define RED/GREEN documentation validation tests.
```

### Out of scope

```text
No Elixir implementation code.
No Ash resource modules.
No migrations.
No Ash policies implemented.
No token generation code.
No QR rendering code.
No Paystack client implementation.
No Meta API implementation.
No Oban workers.
No LiveView/admin UI.
No customer ticket page.
No scanner changes.
```

---

## 4. Domain and Ash Details

### Ash domain

```text
FastCheck.Sales
```

### Actor types requiring policy definition

```text
system
admin
operator
customer_session
```

### Ash resources referenced but not implemented

```text
FastCheck.Sales.TicketOffer
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.PaymentEvent
FastCheck.Sales.TicketIssue
FastCheck.Sales.DeliveryAttempt
FastCheck.Sales.Conversation
FastCheck.Sales.StateTransition
```

### Sensitive fields to classify

```text
Order:
  buyer_name
  buyer_phone
  buyer_email
  public_reference
  idempotency_key
  manual_review_reason
  last_error_message

PaymentAttempt:
  provider_reference
  idempotency_key
  authorization_url
  access_code
  provider_status
  failure_message
  raw_initialize_response
  raw_verify_response

PaymentEvent:
  provider_event_id
  provider_reference
  payload_hash
  raw_payload
  last_processing_error

TicketIssue:
  ticket_code
  qr_token_hash
  delivery_token_hash
  delivery_token_expires_at
  scanner_status
  revocation_reason

DeliveryAttempt:
  recipient
  provider_message_id
  provider_error_code
  provider_error_message
  failure_reason
  correlation_id

Conversation:
  phone_e164
  wa_id
  session_key
  rate_limit_key
  state_data
  last_inbound_message_id
  last_outbound_message_id
  handoff_reason

StateTransition:
  reason
  metadata
  correlation_id
  request_id
  idempotency_key
```

### Non-Ash boundaries to preserve

```text
Paystack client/verifier stays outside Ash resources.
Meta Cloud API client/verifier stays outside Ash resources.
Token generation and QR payload logic stay outside Ash resources.
Redis inventory mutation stays outside Ash resources.
Existing Attendee/scanner validity stays in existing Ecto/scanner path.
```

---

## 5. Required Files / Artifacts

The coding agent should create documentation artifacts only.

Recommended repo paths:

```text
docs/fastcheck_sales/slices/VS-00B_SECURITY_PII_AND_TOKEN_POLICY_FINALIZATION.md
docs/fastcheck_sales/security/SECURITY_PII_TOKEN_MASTER.md
docs/fastcheck_sales/security/PII_DATA_CLASSIFICATION.md
docs/fastcheck_sales/security/ASH_FIELD_ACCESS_POLICY.md
docs/fastcheck_sales/security/ADMIN_OPERATOR_DISPLAY_POLICY.md
docs/fastcheck_sales/security/CUSTOMER_TOKEN_POLICY.md
docs/fastcheck_sales/security/LOG_REDACTION_POLICY.md
docs/fastcheck_sales/security/RAW_PROVIDER_PAYLOAD_POLICY.md
docs/fastcheck_sales/security/SECRET_AND_CONFIG_POLICY.md
docs/fastcheck_sales/security/TENANT_EVENT_ACCESS_POLICY.md
docs/fastcheck_sales/security/PAYSTACK_SECURITY_POLICY.md
docs/fastcheck_sales/security/META_WHATSAPP_SECURITY_POLICY.md
docs/fastcheck_sales/security/SECURITY_TEST_PLAN.md
```

If the repo already has a different docs convention, follow the existing convention but keep names explicit and searchable.

---

## 6. Required Policy Format

Every security policy document must include:

```text
purpose
scope
sensitive fields covered
allowed actors
forbidden actors
masking/redaction rules
storage rules
logging rules
cache/key rules
retention rules where relevant
required future tests
acceptance criteria
```

Every policy must explicitly say whether it applies to:

```text
WhatsApp sales
web checkout sales
admin-assisted sales
internal pilot sales
```

Default rule:

```text
A policy applies to all sales channels unless the policy explicitly says otherwise.
```

---

## 7. Required Security Policies

## 7.1 PII data classification

The PII classification document must classify at least:

| Data | Classification | Notes |
|---|---|---|
| buyer_name | PII | Mask in list views where possible. |
| buyer_phone | PII | Normalize to E.164 where possible. |
| buyer_email | PII | Mask in list views where possible. |
| phone_e164 | PII | WhatsApp identity. |
| wa_id | PII/provider identity | Treat as sensitive. |
| recipient | PII | Delivery target. |
| raw_payload | sensitive provider payload | Restricted to admin/system. |
| raw_initialize_response | sensitive provider payload | Restricted to admin/system. |
| raw_verify_response | sensitive provider payload | Restricted to admin/system. |
| authorization_url | sensitive payment URL | Never log. Customer-visible only when intended. |
| access_code | sensitive provider secret-like value | Never log. Operator hidden. |
| delivery_token_hash | sensitive token hash | Hash only; no plaintext token storage. |
| qr_token_hash | sensitive token hash | Hash only; no plaintext token storage. |
| ticket_code | sensitive customer ticket identifier | Do not expose in broad list views unnecessarily. |
| provider_reference | payment reference | Sensitive in logs and support views. |
| idempotency_key | internal safety key | Do not expose to customer/operator by default. |

Required rules:

```text
Do not use floats for money.
Do not store plaintext customer-facing tokens.
Do not use sequential DB IDs as customer-facing references.
Do not place phone numbers, emails, access codes, authorization URLs, or plaintext tokens in logs.
Do not put PII directly into Redis key names where avoidable.
```

---

## 7.2 Ash field-level access policy

The Ash field-access policy must define actor access for every sensitive field.

Minimum actor rules:

```text
system:
  May access sensitive fields required for processing.
  Must not log sensitive fields by default.

admin:
  May access detailed support/payment views when needed.
  May access raw provider payloads only through restricted views.
  Must have audit trail for dangerous manual actions.

operator:
  May view support summaries.
  Must see masked phone/email by default in list views.
  Must not view raw provider payloads by default.
  Must not view access_code by default.
  Must not perform broad data exports unless explicitly approved.

customer_session:
  May access only controlled customer-facing ticket/order data through secure token/session flow.
  Must never perform broad Ash reads.
  Must never access raw provider payloads, access codes, internal ids, or audit metadata.
```

The policy must include a matrix like this:

| Resource | Field | system | admin | operator | customer_session | Masking / restriction |
|---|---|---:|---:|---:|---:|---|
| Order | buyer_phone | allow | allow detail | masked list / allow support detail | only own controlled flow | E.164 masked in lists |
| PaymentAttempt | raw_verify_response | allow | restricted | deny | deny | raw payload restricted |
| TicketIssue | delivery_token_hash | allow | restricted | deny | deny | never expose hash in UI |

---

## 7.3 Admin/operator display policy

The display policy must define safe defaults for list pages and detail pages.

Required list-view rules:

```text
Mask phone numbers by default.
Mask email addresses by default.
Do not show access_code.
Do not show raw provider payloads.
Do not show delivery_token_hash or qr_token_hash.
Do not show full provider response errors by default if they contain PII.
Use public_reference, status, amount, channel, and timestamps for normal list views.
```

Required detail-view rules:

```text
Admin may reveal more detail when required for support.
Operator detail access must be narrower than admin detail access.
Raw payload reveal should be explicit and restricted.
Manual reveal actions should be auditable if practical.
```

Recommended masking examples:

```text
+2782******34
j***@example.com
provider_reference shown as first6...last4 where possible
```

---

## 7.4 Customer token policy

The customer token policy must cover:

```text
delivery token generation expectations
token hashing at rest
token expiry
token revocation
token rotation on resend if required
QR token hashing
safe customer ticket-page access
invalid-token behavior
expired-token behavior
revoked-ticket behavior
log redaction for token-bearing URLs
```

Required rules:

```text
Plaintext delivery tokens must never be stored.
Only token hashes may be stored.
Token-bearing URLs must not be logged.
Delivery tokens must expire or be revocable.
Revoked/refunded/cancelled tickets must invalidate or block customer ticket access.
Secure ticket page must never expose raw internal ids or provider internals.
```

Recommended customer-facing failure behavior:

| Case | Customer-facing behavior |
|---|---|
| invalid token | Show generic invalid/expired link message. Do not reveal whether ticket exists. |
| expired token | Show safe expired-link message and support/resend path if allowed. |
| revoked ticket | Show contact/support message. Do not show scannable QR. |
| payment pending | Do not say payment does not exist if durable payment state exists. |

---

## 7.5 Log redaction policy

The log-redaction policy must define fields that must never be logged in plaintext.

Required redacted values:

```text
buyer_name
buyer_phone
buyer_email
phone_e164
wa_id
recipient
access_code
authorization_url
raw_initialize_response
raw_verify_response
raw_payload
plaintext delivery token
plaintext QR token
provider payloads containing customer data
Paystack signature/header values if sensitive
Meta webhook signature/header values if sensitive
session_key
rate_limit_key
idempotency_key where unnecessary
```

Allowed log metadata:

```text
public_reference
resource id where internal-only logs are protected
status/state
provider name
event type
amount_cents
currency
correlation_id
request_id
worker job id
masked provider_reference
```

Required rule:

```text
Debug logs in development must follow the same redaction expectations for secrets and tokens.
```

---

## 7.6 Raw provider payload policy

The raw provider payload policy must define:

```text
where raw payloads may be stored
who may read them
how long they are retained
how they are redacted in logs
how they are displayed in admin tools
whether encryption-at-rest is required
whether payload minimization is required
```

Minimum retention decision:

```text
VS-00B must produce the raw provider payload retention policy before VS-07A webhook ingestion is implemented.
```

Required access rules:

```text
system may process raw payloads.
admin may access raw payloads only in restricted/debug/support views.
operator may not access raw payloads by default.
customer_session may never access raw payloads.
```

Required provider-specific notes:

```text
Paystack webhook raw payloads may contain customer/payment metadata.
Meta webhook raw payloads may contain customer identifiers and message content.
WhatsApp state_data may contain customer-entered data and must be treated as sensitive.
```

---

## 7.7 Secret and config policy

The secret/config policy must cover:

```text
Paystack secret keys
Paystack public keys if used
Meta access tokens
Meta app secret
webhook verification secrets
Phoenix secret_key_base
signing salts/keys for tokens
runtime environment variables
release/runtime config
```

Rules:

```text
Secrets must not be committed to the repo.
Secrets must not be placed in planning docs.
Runtime config must read secrets from environment or accepted secret store.
Tests must use fake/sandbox secrets only.
Provider clients must avoid logging request headers or secrets.
```

---

## 7.8 Tenant/event access policy

The tenant/event policy must answer:

```text
Is FastCheck Sales single-tenant or multi-tenant for first release?
If single-tenant, what coding choices must avoid blocking later tenant isolation?
If multi-tenant/future multi-tenant, what owner field is used?
How are admin/operator records scoped by event or organization?
How are customer_session reads scoped to one token/session/order?
```

Default safe rule:

```text
No admin/operator list action may return records across unrelated events or organizations unless the actor is explicitly allowed to do so.
```

Required future test rule:

```text
If organization_id or equivalent tenant scope is accepted, policy tests must prove cross-tenant reads are denied.
```

---

## 7.9 Paystack security policy

The Paystack security policy must define:

```text
webhook signature verification expectation
server-side transaction verification requirement
amount/currency/reference checks
authorization_url exposure rules
access_code storage/display rules
raw response storage rules
sandbox vs production config separation
retry/idempotency logging rules
```

Required rules:

```text
Paystack webhook payload alone is not payment authority.
Only server-side verification can move PaymentAttempt to verified_success.
authorization_url may be sent to the customer only through intended channel.
access_code must not be shown to operator/customer or logged.
amount, currency, provider status, and provider reference must match before payment is accepted.
```

---

## 7.10 Meta/WhatsApp security policy

The Meta/WhatsApp security policy must define:

```text
webhook verification expectation
message dedupe expectations
WhatsApp customer identifiers as PII
message content/state_data sensitivity
24-hour window handling visibility
approved template fallback safety
operator/human handoff data access
rate-limit key safety
```

Required rules:

```text
Meta webhook payloads and WhatsApp message content may contain PII.
WhatsApp must not own payment authority, inventory authority, ticket issuance, or scanner validity.
WhatsApp state must call approved Sales/Checkout services.
Payment-pending messages must not contradict durable payment state.
```

---

## 8. RED / GREEN Documentation Tests

These are documentation contract tests. They must fail before VS-00B is complete and pass after the pack is accepted.

### RED checks

VS-00B is not accepted while any of these are true:

```text
No PII data classification exists.
No Ash field-level access policy exists.
No admin/operator masking policy exists.
No customer token policy exists.
No log-redaction policy exists.
No raw provider payload policy exists.
No secret/config policy exists.
No tenant/event access policy exists.
No Paystack security policy exists.
No Meta/WhatsApp security policy exists.
Plaintext customer-facing token storage is allowed.
authorization_url or access_code may be logged.
operator can view raw provider payloads by default.
customer_session can perform broad Ash reads.
raw provider payload retention is undefined.
phone/email masking is not specified for admin/operator list views.
Paystack webhook payload alone can be treated as payment authority.
WhatsApp is allowed to own payment, inventory, ticket issuance, or scanner validity.
```

### GREEN checks

VS-00B is accepted only when all of these pass:

```text
All required security documents exist.
Sensitive fields are classified per resource.
Every actor type has explicit field-access expectations.
Admin and operator display rules are separate.
Operator access is narrower than admin access.
Customer-session access is limited to controlled token/session/order flow.
Raw provider payload access is restricted and retention is defined.
Customer-facing token policy requires hashing, expiry/revocation, and log redaction.
Log-redaction policy lists fields that must never be logged.
Paystack policy requires signature checks and server-side verification.
Meta/WhatsApp policy treats WhatsApp identifiers/message content as PII.
Tenant/event access direction is explicitly decided or deferred with constraints.
No implementation code is added.
```

Optional command-style documentation checks:

```bash
grep -R "PII" docs/fastcheck_sales/security
grep -R "delivery_token_hash" docs/fastcheck_sales/security
grep -R "access_code" docs/fastcheck_sales/security
grep -R "raw provider payload" docs/fastcheck_sales/security
grep -R "customer_session" docs/fastcheck_sales/security
grep -R "WhatsApp must not own" docs/fastcheck_sales/security
grep -R "server-side verification" docs/fastcheck_sales/security
```

These grep checks are sanity checks only. Human review decides acceptance.

---

## 9. Acceptance Criteria

VS-00B is complete when:

```text
All required security policy docs exist.
PII and sensitive provider fields are classified.
Ash field-level access expectations exist for system/admin/operator/customer_session.
Admin/operator display masking is defined.
Customer-facing token hashing, expiry, revocation, and log-redaction rules are defined.
Raw provider payload storage, access, and retention rules are defined.
Log redaction rules are explicit for Paystack, Meta, WhatsApp, tokens, and PII.
Secret/config handling rules are explicit.
Tenant/event access direction is decided or constrained.
Paystack security policy requires signature checks plus server-side verification.
Meta/WhatsApp security policy treats message data and identifiers as sensitive.
Future implementation test expectations are documented.
No implementation code was added.
```

---

## 10. Future RED / GREEN Implementation Test Expectations

Later implementation slices must convert this policy into actual tests.

Required future test categories:

```text
Ash policy tests for field-level restrictions.
Admin/operator list masking tests.
Customer token invalid/expired/revoked access tests.
Log redaction tests for payment initialization.
Log redaction tests for Paystack webhook ingestion.
Log redaction tests for Meta webhook ingestion.
Raw provider payload access tests.
customer_session broad-read denial tests.
operator raw-payload denial tests.
Tenant/event isolation tests if tenanting is accepted.
No plaintext token persistence tests.
No token-bearing URL logging tests.
```

Example future RED tests:

```text
operator can read PaymentEvent.raw_payload by default -> should fail.
customer_session can list Sales.Order records broadly -> should fail.
logs include Paystack authorization_url -> should fail.
delivery_token stored plaintext -> should fail.
revoked token still renders QR -> should fail.
```

Example future GREEN tests:

```text
admin can access restricted raw payload detail through approved view.
operator sees masked buyer_phone in dashboard list.
customer_session can access only a valid token-scoped ticket page.
expired token does not reveal whether ticket exists.
Paystack access_code never appears in captured logs.
```

---

## 11. Coding-Agent TOON Prompt

| Field | Content |
|---|---|
| Task | Create the VS-00B security, PII, and token policy planning documents for FastCheck Sales. |
| Objective | Define field access, PII masking, token hashing/expiry/revocation, raw provider payload retention/access, log redaction, provider security, and tenant/event access rules before Ash resources, provider integrations, admin UI, ticket pages, or WhatsApp flows are implemented. |
| Output | `docs/fastcheck_sales/slices/VS-00B_SECURITY_PII_AND_TOKEN_POLICY_FINALIZATION.md` plus the security policy documents under `docs/fastcheck_sales/security/`. |
| Note | Do not write application code. Do not create Ash resources, migrations, Ash policies, provider clients, token code, LiveView UI, Oban workers, Redis scripts, or scanner changes. Operator access must be narrower than admin access. Customer-facing tokens must be hash-only at rest. Raw provider payloads must be restricted. Logs must redact PII, provider secrets, access codes, authorization URLs, raw payloads, and plaintext tokens. WhatsApp is the primary channel but must not own inventory, payment authority, ticket issuance, or scanner validity. |

---

## 12. Copy-Paste Prompt for Coding Agent

```text
You are working on FastCheck Sales, an Elixir Phoenix / Ash 3.x planning project.

Implement only the VS-00B Security, PII, and Token Policy Finalization slice.

Your job is documentation and planning only. Do not write application code, migrations, Ash resources, Ash policies, Redis scripts, Paystack code, Meta API code, token generation code, Oban workers, LiveView UI, customer ticket pages, or scanner changes.

Use these source docs as the current planning baseline:
- docs/fastcheck_sales/docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
- docs/fastcheck_sales/docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md

Create or update:
- docs/fastcheck_sales/slices/VS-00B_SECURITY_PII_AND_TOKEN_POLICY_FINALIZATION.md
- docs/fastcheck_sales/security/SECURITY_PII_TOKEN_MASTER.md
- docs/fastcheck_sales/security/PII_DATA_CLASSIFICATION.md
- docs/fastcheck_sales/security/ASH_FIELD_ACCESS_POLICY.md
- docs/fastcheck_sales/security/ADMIN_OPERATOR_DISPLAY_POLICY.md
- docs/fastcheck_sales/security/CUSTOMER_TOKEN_POLICY.md
- docs/fastcheck_sales/security/LOG_REDACTION_POLICY.md
- docs/fastcheck_sales/security/RAW_PROVIDER_PAYLOAD_POLICY.md
- docs/fastcheck_sales/security/SECRET_AND_CONFIG_POLICY.md
- docs/fastcheck_sales/security/TENANT_EVENT_ACCESS_POLICY.md
- docs/fastcheck_sales/security/PAYSTACK_SECURITY_POLICY.md
- docs/fastcheck_sales/security/META_WHATSAPP_SECURITY_POLICY.md
- docs/fastcheck_sales/security/SECURITY_TEST_PLAN.md

Required actor types:
- system
- admin
- operator
- customer_session

Required sensitive resources/fields to classify:
- Order: buyer_name, buyer_phone, buyer_email, public_reference, idempotency_key
- PaymentAttempt: provider_reference, authorization_url, access_code, raw_initialize_response, raw_verify_response
- PaymentEvent: provider_event_id, provider_reference, raw_payload, payload_hash
- TicketIssue: ticket_code, qr_token_hash, delivery_token_hash, delivery_token_expires_at, scanner_status
- DeliveryAttempt: recipient, provider_message_id, provider_error_code, provider_error_message, failure_reason
- Conversation: phone_e164, wa_id, session_key, rate_limit_key, state_data, message ids
- StateTransition: reason, metadata, correlation_id, request_id, idempotency_key

Required rules:
- Plaintext customer-facing tokens must never be stored.
- delivery_token_hash and qr_token_hash are hashes only.
- Token-bearing URLs must not be logged.
- authorization_url and access_code must not be logged.
- Raw provider payload access is restricted to system/admin-only restricted views.
- Operator access is narrower than admin access.
- customer_session must never perform broad Ash reads.
- Admin/operator list views must mask phone/email by default.
- Raw provider payload retention must be defined before webhook ingestion is implemented.
- Secrets must not be committed or placed in planning docs.
- Paystack webhook payload alone is not payment authority.
- Paystack verified_success requires server-side verification and amount/currency/reference checks.
- Meta/WhatsApp identifiers and message content are sensitive.
- WhatsApp is the primary production channel, but WhatsApp must not own payment, inventory, ticket issuance, or scanner validity.
- Web/admin/internal sales paths must follow the same security and token policies.

Acceptance criteria:
- All required security docs exist.
- PII and sensitive fields are classified.
- Field-level actor access expectations are defined.
- Admin/operator masking rules are defined.
- Token hashing/expiry/revocation/log-redaction rules are defined.
- Raw payload access and retention are defined.
- Log redaction rules are explicit.
- Paystack and Meta/WhatsApp security rules are explicit.
- Future RED/GREEN implementation test expectations are documented.
- No implementation code is added.
```

---

## 13. Human Review Checklist

Before marking VS-00B done, confirm:

```text
No policy allows plaintext customer-facing token storage.
No policy allows token-bearing URLs in logs.
No policy allows access_code or authorization_url in logs.
No policy allows operator raw-provider-payload access by default.
No policy allows customer_session broad reads.
Phone/email masking is explicit for list views.
Admin and operator privileges are clearly different.
Raw provider payload retention is explicit.
Paystack verification authority is backend/server-side only.
Meta/WhatsApp payloads are treated as PII/sensitive data.
Tenant/event access direction is explicitly decided or constrained.
All sales channels share the same security policy.
No implementation code was added.
```

---

## 14. Success Definition

VS-00B succeeds when future coding agents cannot reasonably introduce unsafe handling for:

```text
buyer names
phone numbers
email addresses
WhatsApp identifiers
Paystack access codes
authorization URLs
raw Paystack payloads
raw Meta payloads
customer-facing ticket tokens
QR tokens
admin/operator support views
customer_session access
logs and telemetry
```

The correct understanding must be:

```text
Security policy is channel-wide.
WhatsApp is first, but not privileged to bypass policy.
Operator is not admin.
Customer_session is tightly scoped.
Raw provider payloads are restricted.
Tokens are hash-only at rest.
Logs are redacted by default.
Payment authority remains backend verified.
Ticket access remains token-scoped and revocation-aware.
```
