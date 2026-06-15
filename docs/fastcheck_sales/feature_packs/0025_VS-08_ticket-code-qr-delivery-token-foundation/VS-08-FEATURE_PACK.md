# FastCheck Sales Feature Planning Pack — VS-08 Ticket Code, QR, and Delivery Token Foundation

**Pack ID:** `0025_VS-08_ticket-code-qr-delivery-token-foundation`  
**Slice:** `VS-08`  
**Slice name:** Ticket Code, QR, and Delivery Token Foundation  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Repository path:** `docs/fastcheck_sales/feature_packs/0025_VS-08_ticket-code-qr-delivery-token-foundation/`  
**Status:** Implementation planning pack — implementation allowed inside this slice only  
**Primary area:** Tickets / Security / Token Foundation / QR Payloads  
**Depends on:** VS-01D, VS-01F, VS-01G, VS-00A, VS-00B, VS-21A  
**Blocks:** VS-09A, VS-09B, VS-09C, VS-09D, VS-11, VS-15A, VS-19, VS-20, VS-22  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack instructs a coding agent to implement the **secure ticket identifier foundation** used later by ticket issuance, QR rendering, secure ticket-page access, WhatsApp/email delivery, and scanner-safe revocation.

VS-08 must create the primitives, contracts, and tests for:

```text
secure ticket code generation
scanner QR payload construction/parsing boundary
QR token hashing
customer delivery token generation
customer delivery token hashing
customer delivery token expiry semantics
customer delivery token revocation semantics
safe logging/redaction for all ticket/customer tokens
```

Critical principle:

```text
Identifiers are not ticket issuance.
QR/token generation must not create customer value by itself.
Only VS-09 may issue tickets from verified paid orders.
Only later scanner/revocation slices may change scanner acceptance behavior.
```

VS-08 owns the security foundation that later slices use.

VS-08 does **not** own:

```text
ticket issuance
TicketIssue creation from orders
Attendee creation
existing scanner route changes
existing scanner hot-path changes
mobile sync changes
ticket delivery attempts
secure ticket page controller
WhatsApp or Meta messages
email delivery
Paystack or payment state changes
inventory changes
```

---

## 2. Ultimate Outcome

After VS-08 is complete:

```text
The system can generate non-sequential ticket codes with enough entropy for public/support use.
The system can generate QR payload tokens without including PII or sequential database IDs.
The system can generate customer delivery tokens that are stored only as hashes.
Plaintext QR/delivery tokens exist only in memory at generation/render/send time.
Token hashing uses a dedicated secret/pepper and never logs plaintext values.
Delivery token expiry and revocation semantics are defined and testable.
TicketIssue has the required fields/indexes for later token lookup and revocation without table scans.
No ticket is issued, no Attendee is created, and no scanner behavior changes in this slice.
```

The system is then ready for VS-09A to define ticket issuance idempotency and for VS-11 to build the secure ticket page using the hashed delivery token foundation.

---

## 3. Scope

### In scope

```text
Add plain Elixir ticket security modules under lib/fastcheck/tickets/.
Implement or finalize TicketCode generation primitives.
Implement or finalize QR payload construction and parsing primitives.
Implement or finalize DeliveryToken generation, hashing, expiry, verification, and revocation helper semantics.
Add config boundary for ticket-token secret/pepper if none exists.
Add missing TicketIssue indexes/constraints for ticket_code, qr_token_hash, and delivery_token_hash if they are not already present.
Add RED/GREEN tests for entropy, format, no-PII payloads, token hashing, expiry, revocation, log redaction, and boundary creep.
Document the exact QR payload format chosen for the first release.
Document whether QR token and delivery token are separate tokens.
```

### Out of scope

```text
No TicketIssue creation from Order/OrderLine.
No Tickets.Issuer implementation.
No Attendee creation or mutation.
No existing scanner route or hot-path change.
No mobile sync version bump.
No QR image rendering requirement unless a tiny payload-rendering helper already exists and only needs input validation.
No ticket delivery controller/page.
No DeliveryAttempt creation.
No WhatsApp/Meta/email sending.
No Paystack/payment/order state mutation.
No Redis inventory mutation.
No admin UI.
No broad new token-history resource unless explicitly approved; use existing TicketIssue token fields for MVP.
```

---

## 4. Required Pre-Implementation Discovery

Before changing code, the agent must inspect the repository and document findings in the final report:

```text
Existing FastCheck.Tickets namespace and helper conventions.
Existing ticket/attendee code generation conventions.
Existing QR payload format expected by scanner or Android scanner flows.
Existing scanner lookup field names and whether scanner expects raw code, QR token, attendee id, or another payload format.
Existing Attendee schema fields that store QR/code values.
Existing TicketIssue resource fields and migrations from VS-01D.
Existing token hashing, signed token, or Phoenix.Token conventions in the app.
Existing secrets/config pattern for runtime app secrets.
Existing telemetry/log redaction helper from VS-21A.
Existing tests/factories for TicketIssue and existing Attendee/scanner fixtures.
```

Discovery rule:

```text
If an existing scanner payload format already exists, preserve it.
Do not invent a new scanner payload format that would require scanner hot-path changes in this slice.
```

---

## 5. Identifier Model

Use three separate concepts. Do not collapse them into one unsafe value.

| Concept | Purpose | Public? | Stored plaintext? | Stored hash? | Used by |
|---|---|---:|---:|---:|---|
| `ticket_code` | Human/support reference and durable unique ticket identifier. | Yes, limited. | Yes, as code/reference. | No, unless existing codebase already does. | Admin/support, issuer, future scanner bridge if existing scanner uses code. |
| `qr_token` / QR payload secret | Token embedded in scanner QR payload where the scanner model supports it. | Presented at gate only. | No. | Yes: `qr_token_hash`. | QR payload builder, later issuance/scanner bridge. |
| `delivery_token` | Customer web ticket-page access/resend link token. | Secret bearer token. | No. | Yes: `delivery_token_hash`. | Secure ticket page, WhatsApp/email link delivery. |

Rules:

```text
A ticket_code alone must not grant secure ticket-page access.
A delivery_token must not be used as the scanner QR payload.
A QR token must not be used as the secure ticket-page access token.
No token may include buyer_name, buyer_phone, buyer_email, provider reference, sequential DB id, or raw order id.
Plaintext delivery_token and qr_token values may be returned from generation functions only once and must not be persisted.
```

---

## 6. Recommended Modules and Files

### Preferred implementation files

```text
lib/fastcheck/tickets/code_generator.ex
lib/fastcheck/tickets/qr_payload.ex
lib/fastcheck/tickets/delivery_token.ex
lib/fastcheck/tickets/token_hash.ex
config/runtime.exs                         # only if a dedicated ticket-token secret is missing
priv/repo/migrations/*_add_ticket_token_indexes.exs # only if token indexes are missing
```

### Preferred tests

```text
test/fastcheck/tickets/code_generator_test.exs
test/fastcheck/tickets/qr_payload_test.exs
test/fastcheck/tickets/delivery_token_test.exs
test/fastcheck/tickets/token_hash_test.exs
test/fastcheck/tickets/ticket_token_indexes_test.exs
test/fastcheck/tickets/ticket_token_security_test.exs
test/fastcheck/tickets/ticket_token_boundary_test.exs
```

### Ash resources touched

```text
FastCheck.Sales.TicketIssue       # only field/index/validation readiness; no issuance workflow
```

### Ash resources not to mutate

```text
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.PaymentEvent
FastCheck.Sales.DeliveryAttempt
FastCheck.Sales.Conversation
FastCheck.Sales.StateTransition   # no state transitions expected in VS-08
```

### Existing non-Ash systems not to mutate

```text
FastCheck.Attendees
FastCheck.Attendees.Scan
FastCheck.Attendees.Reconciliation
FastCheck.Events.Sync
Android mobile API
Scanner routes and scanner hot path
```

---

## 7. Ticket Code Rules

Recommended ticket code properties:

```text
minimum 128 bits of randomness
URL/QR safe alphabet
non-sequential
not derived from DB id, order id, phone, email, event id, or provider reference
short enough for support reading when grouped
unique in sales_ticket_issues.ticket_code
safe to display in admin/support views
not sufficient to access secure ticket page
```

Suggested format:

```text
FC-<BASE32_OR_BASE64URL_RANDOM>
```

Implementation guidance:

```text
Use :crypto.strong_rand_bytes/1.
Prefer Base.url_encode64(..., padding: false) or an existing project-safe Base32 helper.
Avoid adding a dependency just for token encoding unless the app already has one.
Keep generator pure and easy to test.
Do not query the database from the generator module.
Database uniqueness/retry belongs to the later issuer flow.
```

Collision handling:

```text
VS-08 generator can expose a function that creates one candidate ticket_code.
VS-09 issuance must retry on DB unique constraint conflict.
Do not add Repo calls inside CodeGenerator just to guarantee uniqueness.
```

---

## 8. QR Payload Rules

Recommended QR payload properties:

```text
versioned payload format when possible
no PII
no raw order id
no raw payment/provider reference
no sequential DB id
small enough for QR rendering/scanning reliability
compatible with existing scanner expectations
separate from delivery_token
parseable with explicit error tuples
```

Preferred approach:

```text
If the existing scanner expects a plain code, generate the scanner-compatible payload from the approved code/token without changing scanner behavior.
If the existing scanner supports opaque tokens, prefer an opaque QR token whose hash is stored as qr_token_hash.
If scanner compatibility is unclear, implement the builder/parser behind FastCheck.Tickets.QrPayload and document the unresolved scanner decision instead of changing scanner code.
```

Recommended payload examples:

```text
FC1:<ticket_code>
FC1:<qr_token>
```

Do not use:

```text
JSON payload with customer PII
base64-encoded order/customer/payment data
signed payload containing sequential IDs
secure ticket delivery URL as the scanner QR payload
```

---

## 9. Delivery Token Rules

Recommended delivery token properties:

```text
minimum 256 bits of randomness
bearer secret
single active token hash on TicketIssue for MVP
stored only as delivery_token_hash
expires at delivery_token_expires_at
revocable by clearing/replacing hash or marking ticket revoked according to later VS-15A rules
safe comparison function available
never logged
never shown in admin/operator list views
```

Hashing guidance:

```text
Use a dedicated ticket token secret/pepper from runtime config.
Hash with HMAC-SHA256 or the existing app token-hashing helper.
Do not use plain SHA256 without a secret/pepper.
Do not use password hashing unless the existing app requires it; these are high-entropy random tokens, not human passwords.
Use constant-time comparison when comparing known hashes.
Fail closed if the token secret is missing in prod/runtime config.
```

Token lifecycle:

```text
generate -> return plaintext once + hash + expires_at
verify -> hash supplied plaintext and compare/hash-lookup
expire -> reject when now > delivery_token_expires_at
revoke -> reject when TicketIssue.status/scanner_status/revoked_at says invalid or when token hash is rotated/cleared
rotate -> generate new plaintext token and new hash; old plaintext token must become invalid after persistence in later slices
```

VS-08 should implement the primitive functions. VS-11 and VS-13/VS-15A will wire them into customer page and admin/revocation workflows.

---

## 10. TicketIssue Field and Index Expectations

The TicketIssue skeleton should already include:

```text
ticket_code
qr_token_hash
delivery_token_hash
delivery_token_expires_at
status
scanner_status
revoked_at
revocation_reason
```

Required constraints/indexes for later slices:

```text
unique(ticket_code)
unique(qr_token_hash) where qr_token_hash is not null
unique(delivery_token_hash) where delivery_token_hash is not null
index(delivery_token_expires_at) where delivery_token_hash is not null
index(status, delivery_token_expires_at)
index(scanner_status)
```

Rules:

```text
Secure ticket page lookup must hash the submitted delivery token first and use an indexed hash lookup.
No secure ticket page or admin lookup may scan sales_ticket_issues by token-related fields.
Partial unique indexes must be used for nullable token hashes.
Do not store plaintext delivery_token or qr_token columns.
```

---

## 11. Security and Logging Requirements

Never log:

```text
plaintext delivery_token
plaintext qr_token
raw QR payload if it contains a bearer token
access_code
authorization_url
buyer_phone
buyer_email
raw provider payload
runtime token secret/pepper
```

Allowed logs:

```text
correlation_id
entity id where internal-only
short redacted token fingerprint, e.g. first 6 chars of hash only, if needed for support diagnostics
token purpose: delivery or qr
success/failure reason code
```

Required failure behavior:

```text
Missing token secret in production -> fail closed.
Malformed token -> return invalid without raising noisy errors.
Expired token -> return expired, not invalid, where safe for support/debugging.
Revoked token -> return revoked.
Token for wrong purpose -> return invalid_purpose or invalid, not successful.
```

---

## 12. Performance and Scaling Review

### Data-layer classification

```text
Hot data: none required for token generation; plaintext tokens exist only in memory.
Warm data: optional Cachex for future secure ticket page metadata, not in VS-08.
Cold data: TicketIssue token hashes and expiry metadata in Postgres.
Browser storage: none in VS-08.
CDN: none in VS-08.
```

### Required indexes

```text
unique(ticket_code)
unique(qr_token_hash) where qr_token_hash is not null
unique(delivery_token_hash) where delivery_token_hash is not null
index(delivery_token_expires_at) where delivery_token_hash is not null
index(status, delivery_token_expires_at)
index(scanner_status)
```

### Caching rules

```text
Do not cache plaintext tokens.
Do not place bearer tokens in PubSub payloads, telemetry metadata, logs, LiveView assigns, or browser localStorage.
Future VS-11 may cache non-sensitive ticket page rendering metadata only after successful token validation.
```

### Invalidation triggers

```text
TicketIssue token rotation -> invalidate secure ticket page cache for that ticket.
TicketIssue revocation/refund/cancellation -> invalidate secure ticket page cache and scanner-facing cache.
Delivery token expiry -> no cache should continue serving the ticket page after expiry.
```

### Redis-side representation

```text
No Redis representation is required for token correctness in VS-08.
Future rate limiting for secure ticket page access may use Redis sorted sets in VS-11/VS-20.
Do not add Redis token storage in VS-08.
```

### PubSub rules

```text
No PubSub required in VS-08.
Future revocation/token rotation broadcasts must include only sanitized internal identifiers, never plaintext tokens.
```

### 100k-user safety

```text
Token generation is CPU-light and memory-local.
Token lookup must be indexed by hash in future VS-11.
No token validation path may perform large table scans.
No QR payload builder should load entire orders, events, or ticket lists into memory.
```

---

## 13. RED/GREEN Test Plan

### 13.1 Ticket code tests

```text
RED ticket code is sequential or derived from DB id/order id.
GREEN ticket code is random, non-sequential, URL/QR safe, and not derived from input PII or IDs.

RED ticket code has too little entropy or a tiny namespace.
GREEN generator uses at least 128 bits of randomness.

RED ticket_code unique DB constraint is missing.
GREEN sales_ticket_issues has unique(ticket_code).
```

### 13.2 QR payload tests

```text
RED QR payload includes buyer_name, buyer_phone, buyer_email, order id, payment reference, or delivery URL.
GREEN QR payload includes only the approved version prefix and opaque ticket/QR value.

RED QR parser accepts arbitrary malformed payloads silently.
GREEN parser returns explicit {:ok, parsed} or {:error, reason} results.

RED VS-08 changes scanner routes or Android scanner behavior.
GREEN no scanner/mobile code paths are modified.
```

### 13.3 Delivery token tests

```text
RED plaintext delivery_token is stored in TicketIssue or logs.
GREEN only delivery_token_hash is persisted/logged in redacted form.

RED token hash uses plain SHA256 without a secret/pepper.
GREEN token hash uses HMAC/approved secret-backed hashing.

RED two generated delivery tokens are predictable or reused.
GREEN generated delivery tokens use at least 256 bits of randomness.

RED token validation ignores delivery_token_expires_at.
GREEN expired token returns expired/failure and cannot access ticket content.

RED revoked TicketIssue token still validates successfully.
GREEN revoked/refunded/cancelled ticket state causes token validation to reject.

RED missing token secret in production falls back to insecure default.
GREEN missing token secret fails closed.
```

### 13.4 Index and lookup tests

```text
RED lookup by delivery token scans sales_ticket_issues or compares plaintext values.
GREEN lookup requires hash-first and indexed delivery_token_hash query in future service contract.

RED qr_token_hash lacks unique partial index.
GREEN qr_token_hash has a partial unique index when present.

RED delivery_token_hash lacks unique partial index.
GREEN delivery_token_hash has a partial unique index when present.
```

### 13.5 Boundary creep tests

```text
RED VS-08 creates TicketIssue records from paid orders.
GREEN VS-08 only provides generation/hash/index foundations.

RED VS-08 creates or mutates Attendee rows.
GREEN no FastCheck.Attendees mutation exists.

RED VS-08 enqueues IssueTicketsWorker or SendWhatsAppTicketWorker.
GREEN no issuance/delivery workers are enqueued.

RED VS-08 changes Order, PaymentAttempt, PaymentEvent, CheckoutSession, or inventory state.
GREEN no payment/order/checkout/inventory state changes exist.

RED VS-08 sends WhatsApp/email messages or creates DeliveryAttempt rows.
GREEN no delivery behavior exists.
```

### 13.6 Logging/security tests

```text
RED logs include plaintext delivery token, QR token, raw QR bearer payload, buyer email, buyer phone, or token secret.
GREEN logs only include sanitized metadata and optional redacted hash fingerprint.

RED telemetry metadata includes plaintext token.
GREEN telemetry metadata includes only non-sensitive reason/status counters.
```

---

## 14. Acceptance Criteria

This slice is complete only when:

```text
Ticket code generator exists and is tested.
QR payload builder/parser exists and is tested.
Delivery token generation/hash/verify/expiry helpers exist and are tested.
Token secret/config behavior is fail-closed in production.
TicketIssue has required token hash fields and indexes, or migration verification confirms they already exist.
No plaintext qr_token or delivery_token column exists.
No token/PII/log redaction test fails.
No scanner, Attendee, mobile sync, payment, WhatsApp, or delivery behavior is modified.
The final implementation report states the exact QR payload compatibility decision discovered from existing scanner code.
The final implementation report lists any deferred integration needed for VS-09B, VS-11, and VS-15A.
```

---

## 15. Failure Modes and Risk Review

| Risk | Mitigation |
|---|---|
| Token accidentally logged. | Add log capture/redaction tests and never inspect plaintext in logs. |
| Delivery token reused as QR scanner token. | Keep separate modules/functions/purposes and tests for token purpose separation. |
| QR payload includes PII. | Add negative tests for buyer/customer/provider fields in payload. |
| Scanner format guessed incorrectly. | Require discovery and preserve existing scanner format; do not modify scanner in VS-08. |
| Token hash not indexed. | Add partial unique indexes for hash fields. |
| Ticket code collision under high volume. | Use >=128-bit randomness and DB unique constraint; issuer later retries on conflict. |
| Delivery token brute force. | Use >=256-bit random tokens, secret-backed hash, rate limiting later in VS-11/VS-20. |
| Missing runtime secret leads to insecure default. | Fail closed in prod/runtime config. |
| Revoked ticket page still accessible. | Token verification helpers must consider TicketIssue revoked/refunded/cancelled state when provided. |
| Premature ticket value delivery. | No TicketIssue creation, Attendee mutation, delivery, or scanner changes in VS-08. |

---

## 16. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement the VS-08 ticket identifier foundation for FastCheck Sales by adding secure ticket-code, QR-payload, delivery-token, and token-hash primitives, plus any missing TicketIssue token indexes. |
| Objective | Provide safe, reusable ticket security primitives for later issuance, secure ticket-page, WhatsApp/email delivery, and scanner integration without issuing tickets or changing scanner behavior in this slice. |
| Output | Add/update `lib/fastcheck/tickets/code_generator.ex`, `lib/fastcheck/tickets/qr_payload.ex`, `lib/fastcheck/tickets/delivery_token.ex`, `lib/fastcheck/tickets/token_hash.ex`, and only-if-missing token index migrations for `sales_ticket_issues`. Add tests under `test/fastcheck/tickets/*_test.exs`. Final report must include scanner payload discovery notes and confirmation that no scanner/Attendee/payment/delivery behavior changed. |
| Note | Use `:crypto.strong_rand_bytes/1`; ticket codes require >=128 bits entropy; delivery tokens require >=256 bits entropy; use secret-backed HMAC/approved project helper for token hashes; no plaintext `delivery_token` or `qr_token` persistence; no PII/sequential IDs/provider refs in QR payloads; preserve existing scanner payload format if found; do not add Repo calls inside generators; add/verify `unique(ticket_code)`, partial unique indexes for `qr_token_hash` and `delivery_token_hash`, `index(delivery_token_expires_at)` where applicable, `index(status, delivery_token_expires_at)`, and `index(scanner_status)`; no Redis token storage; no PubSub; no TicketIssue creation from orders; no Attendee mutation; no scanner/mobile changes; no WhatsApp/email/DeliveryAttempt; no Paystack/order/payment/inventory state changes; logs/telemetry must never include plaintext tokens, raw bearer QR payloads, PII, provider payloads, or runtime secrets. |

---

## 17. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-08 — Ticket Code, QR, and Delivery Token Foundation.

Goal:
Add secure ticket identifier primitives only. Do not issue tickets and do not touch scanner behavior.

Read first:
- FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
- FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
- Existing TicketIssue resource/migrations from VS-01D
- Existing scanner/Attendee QR/code expectations
- Existing log redaction/config conventions

Implement only:
- lib/fastcheck/tickets/code_generator.ex
- lib/fastcheck/tickets/qr_payload.ex
- lib/fastcheck/tickets/delivery_token.ex
- lib/fastcheck/tickets/token_hash.ex
- only-if-needed migration/index updates for sales_ticket_issues token fields
- tests under test/fastcheck/tickets/

Rules:
- ticket_code uses at least 128 bits of randomness, is non-sequential, URL/QR safe, and not derived from DB id/order id/customer/provider data.
- delivery_token uses at least 256 bits of randomness and is stored only as delivery_token_hash.
- QR token, if used, is stored only as qr_token_hash.
- Use secret-backed HMAC/approved helper for token hashing; never plain SHA256 without a secret.
- Missing token secret in production must fail closed.
- QR payload must include no PII, raw order ids, payment/provider refs, delivery URL, or customer data.
- Preserve existing scanner payload expectations. Do not change scanner route, Android scanner, Attendee scan logic, or mobile sync in this slice.
- Do not create TicketIssue records from orders.
- Do not create/mutate Attendee rows.
- Do not enqueue IssueTicketsWorker, SendWhatsAppTicketWorker, or delivery workers.
- Do not mutate Order, PaymentAttempt, PaymentEvent, CheckoutSession, Redis inventory, Paystack, WhatsApp, or DeliveryAttempt behavior.
- Do not log plaintext tokens, raw QR bearer payloads, PII, provider payloads, access_code, authorization_url, or runtime secrets.

Tests must prove:
- ticket code entropy/format/non-sequential behavior
- no PII/sequential/provider data in QR payload
- delivery token plaintext is never persisted or logged
- token hashes are secret-backed and deterministic for lookup
- expired/revoked token semantics are rejected by helper contracts
- required token indexes exist or are explicitly added
- no scanner/Attendee/payment/order/inventory/delivery/WhatsApp boundary creep exists

Final report:
- List files changed.
- State discovered scanner payload expectation.
- State exact QR payload format used.
- State token hash algorithm/config key used.
- Confirm no plaintext token storage/logging.
- Confirm no scanner/Attendee/payment/delivery behavior changed.
```

---

## 18. Human Review Checklist

```text
[ ] The pack does not instruct the agent to issue tickets.
[ ] The pack does not allow Attendee creation/mutation.
[ ] The pack does not allow scanner hot-path changes.
[ ] Ticket code generation is high-entropy and non-sequential.
[ ] Delivery token generation is high-entropy and bearer-secret safe.
[ ] Token hashing is secret-backed and fail-closed if misconfigured.
[ ] Plaintext delivery/QR tokens are not persisted.
[ ] QR payload contains no PII or provider/payment data.
[ ] Required token hash indexes are present or explicitly added.
[ ] Log redaction tests cover plaintext token and PII leakage.
[ ] The scanner payload compatibility decision is documented.
[ ] The next VS-09A issuance pack can consume these primitives without inventing token rules.
```

---

## 19. Next Slice

```text
VS-09A — Ticket Issuance Contract and Idempotency Model
```
