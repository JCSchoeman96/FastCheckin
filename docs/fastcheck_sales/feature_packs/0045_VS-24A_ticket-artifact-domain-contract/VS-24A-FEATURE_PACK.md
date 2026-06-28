# VS-24A — Ticket Artifact Domain Contract

## Status

Implementation-ready planning pack, patched before agent handoff.

## Repository Truth

- Repository: `JCSchoeman96/FastCheckin`
- Default branch: `main`
- Planning date: 2026-06-28
- Feature-pack folder: `docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract`
- Important numbering rule: `0044` is already used by `VS-22_end-to-end-sandbox-tests`. Do not reuse `0044`.
- Handoff rule: implementation handoffs are post-merge documents. Do not add `docs/fastcheck_sales/handoffs/VS-24A_IMPLEMENTATION_HANDOFF.md` in the implementation PR.
- Scope: one feature pack only.
- Implementation code: not included in this pack.

## Purpose

Define the single safe boundary that turns an issued, currently-valid ticket into a customer-facing ticket artifact.

This boundary must later support:

- secure ticket web page
- PDF tickets
- Apple Wallet passes
- Google Wallet passes

This slice must **not** implement PDF, Apple Wallet, or Google Wallet rendering.

The correct authority split is:

```text
Payment authority: Paystack server-side verification
Ticket authority: FastCheck backend issuance
Scanner authority: Attendee + mobile/scanner acceptance path
Artifact authority: read-only customer-safe projection of an issued, currently-valid ticket
Renderers: Secure Web Page / PDF / Apple Wallet / Google Wallet
```

## Hard Rules

- One feature pack only.
- Do not implement PDF generation.
- Do not implement Apple Wallet passes.
- Do not implement Google Wallet passes.
- Do not change payment authority.
- Do not change ticket issuance authority.
- Do not change scanner authority.
- Do not change revocation/refund behavior.
- Do not change WhatsApp delivery behavior.
- Do not duplicate `SecureTicketController`.
- Do not duplicate `TicketPage`.
- Do not duplicate `TicketIssue`.
- Do not duplicate `FastCheck.Tickets.Issuer`.
- Do not expose delivery tokens, delivery token hashes, QR token hashes, ticket URLs, payment URLs, Paystack access codes, raw provider payloads, phone numbers, or emails.
- Do not allow default struct inspection to leak `Artifact.scanner_payload`; custom `Inspect` redaction is required for `Artifact` and `ArtifactError`.
- Do not add routes.
- Do not add persistence.
- Do not add migrations.
- Use current repo code as source of truth.

## 1. Backward Planning

### Ultimate Long-Term Goal

FastCheck should support multiple customer-facing ticket artifact renderers from one shared contract:

1. Secure web ticket page.
2. PDF ticket.
3. Apple Wallet pass.
4. Google Wallet pass.

The long-term goal is **not** four ticket systems. It is one read-only artifact contract consumed by multiple renderers.

### Required Systems Eventually

| System | Role | VS-24A Status |
|---|---|---|
| Payment verification | Confirms payment through Paystack server-side verification | Existing authority; do not change |
| Ticket issuance | Creates attendees and ticket issue rows | Existing authority; do not change |
| Delivery token validation | Possession-based customer artifact access | Existing primitives; reuse |
| Artifact resolver | Converts valid token + current state to safe artifact | Build in VS-24A |
| Secure web page | Current customer-facing page | Refactor to consume artifact contract through adapter |
| PDF renderer | Future artifact renderer | Out of scope |
| Apple Wallet renderer | Future artifact renderer | Out of scope |
| Google Wallet renderer | Future artifact renderer | Out of scope |
| Scanner acceptance | Determines entry validity and mutates scan state | Existing authority; do not change |
| Revocation/refund | Revokes ticket and updates scanner visibility | Existing authority; do not change |

### Dependency Sequence

1. Preserve current secure ticket page behavior.
2. Extract renderer-neutral artifact contract from `FastCheck.Sales.TicketPage` policy.
3. Add a read-only resolver that uses current token, ticket, attendee, event, payment-status, and QR payload rules.
4. Make `FastCheck.Sales.TicketPage.resolve/1` a legacy adapter over the resolver.
5. Lock behavior with resolver, TicketPage, controller, and E2E tests.
6. Leave PDF, Apple Wallet, and Google Wallet as future consumers.

### MVP Slice

The MVP for VS-24A is:

```text
Create a read-only ticket artifact contract and resolver.
Refactor TicketPage to consume it.
Preserve existing secure ticket page result shape.
Do not add renderer-specific implementation.
```

## 2. Domain Model / Resource Map

### Sales Domain

| Resource / Module | Responsibility |
|---|---|
| `FastCheck.Sales.TicketIssue` | Durable ticket issuance audit and linkage. Stores ticket code, attendee link, token hashes, expiry, status, scanner status, revocation fields. |
| `FastCheck.Sales.TicketPage` | Current secure ticket page read boundary. Must become a thin adapter over the new artifact resolver while preserving public result shape. |
| `FastCheck.Sales.DeliveryAttempt` | Durable outbound delivery audit. Tracks channel, provider, redacted recipient, send status, attempt number, provider outcome fields. |
| `FastCheck.Sales.Order` | Sales order and event linkage. |
| `FastCheck.Sales.OrderLine` | Purchased ticket units. |
| `FastCheck.Sales.PaymentAttempt` | Payment verification evidence. Must not be changed in VS-24A. |

### Tickets Domain

| Module | Responsibility |
|---|---|
| `FastCheck.Tickets.DeliveryToken` | Generates and verifies delivery bearer tokens. Plaintext is generated once and must not be persisted. |
| `FastCheck.Tickets.TokenHash` | Purpose-bound HMAC hashing for `:delivery` and `:qr`. |
| `FastCheck.Tickets.QrPayload` | Current scanner QR/text payload compatibility layer. Active scanner expects plain ticket code. |
| `FastCheck.Tickets.Issuer` | Approved backend ticket issuance authority. |
| `FastCheck.Tickets.Revocation` | Approved revocation authority. |
| `FastCheck.Tickets.ScannerVisibility` | Scanner visibility invalidation for revoked tickets. |
| `FastCheck.Tickets.Artifact` | New customer-safe artifact struct. |
| `FastCheck.Tickets.ArtifactError` | New customer-safe non-renderable result struct. |
| `FastCheck.Tickets.ArtifactResolver` | New read-only resolver from delivery token to artifact/error. |

### Attendees / Scanner Domain

| Module | Responsibility |
|---|---|
| `FastCheck.Attendees.Attendee` | Scanner-visible ticket holder row. Holds `ticket_code`, display fields, payment status, scan eligibility, check-in counters, revocation metadata. |
| `FastCheck.Attendees.Scan` | Mutable scanner authority. Handles check-in, check-out, manual entry, row locks, duplicate detection, payment-status rejection, cache invalidation, and stats broadcasting. |

### Messaging / Delivery Domain

| Module | Responsibility |
|---|---|
| `FastCheck.Workers.SendWhatsAppTicketLinkWorker` | Current ticket-link delivery path. Rotates delivery token, validates secure page, creates delivery attempt, sends via WhatsApp. |
| `FastCheck.Messaging.WhatsApp.*` | WhatsApp provider, delivery policy, renderer, and dedupe. Out of scope. |

### New Artifact Contract

Input:

```text
raw delivery bearer token from `/t/:token`
```

Output:

```text
{:ok, %FastCheck.Tickets.Artifact{}}
{:error, %FastCheck.Tickets.ArtifactError{}}
```

Allowed artifact fields:

```text
state
event_name
attendee_name
ticket_type
scanner_payload
scanner_payload_format
support_message
issued_at
delivery_expires_at
```

Allowed error fields:

```text
state
support_message
http_status_hint
```

Forbidden everywhere in artifact structs, error structs, logs, HTML, telemetry, tests, and docs examples:

```text
delivery token
delivery token hash
QR token hash
ticket URL
payment URL
Paystack access code
raw provider payload
phone number
email
buyer_phone
buyer_email
recipient
provider message body
provider request body
authorization_url
access_code
```

Do not embed or expose raw `%TicketIssue{}`, `%Attendee{}`, `%Order{}`, `%DeliveryAttempt{}`, `%Conversation{}` structs inside artifact structs.

Because `scanner_payload` is currently the plain scanner ticket code, `FastCheck.Tickets.Artifact` and `FastCheck.Tickets.ArtifactError` must implement custom `Inspect` behavior. The valid artifact may expose `scanner_payload` as a normal field to renderers, but `inspect(artifact)` must redact it. `inspect(error)` must contain no token, hash, ID, raw payload, phone, email, payment URL, ticket URL, or scanner payload.

## 3. Current Repo Findings

### Secure Ticket Page

`FastCheckWeb.SecureTicketController` resolves `GET /t/:token` by calling `FastCheck.Sales.TicketPage.resolve/1` and rendering the existing secure-ticket template.

Current secure-page behavior to preserve:

- possession-based access through delivery token
- no dashboard/scanner session required
- no-store/private/no-cache/noindex headers
- safe result rendering only
- invalid/expired/revoked/not-ready/not-scannable states do not expose the ticket code

### TicketPage Legacy Shape

`FastCheck.Sales.TicketPage.resolve/1` currently returns a secure-page-shaped map with:

```text
state
event_name
attendee_name
ticket_type
qr_payload
support_message
```

The existing template renders `@result.qr_payload`. Existing tests assert that `result.qr_payload == QrPayload.build_for_scanner(ticket_code)`.

VS-24A may add `Artifact.scanner_payload`, but `TicketPage.resolve/1` must map `artifact.scanner_payload` back to `qr_payload` and preserve the legacy result shape exactly.

Do not change:

```text
lib/fastcheck_web/controllers/secure_ticket_controller.ex
lib/fastcheck_web/controllers/secure_ticket_html/show.html.heex
```

### Delivery Tokens

Existing primitives already do the right thing:

- plaintext token is generated once
- hash is stored
- expiry is stored
- `TokenHash` purpose-binds delivery and QR tokens separately
- production uses `TICKET_TOKEN_PEPPER`

Do not change token generation, rotation, hash format, or storage.

### QR / Scanner Payload

Current scanner compatibility requires plain ticket code.

Use:

```text
FastCheck.Tickets.QrPayload.build_for_scanner(ticket_issue.ticket_code)
```

Do not invent a new barcode format. Do not use QR token hashes. Do not introduce `FC1`/versioned payload output in VS-24A.

### Ticket Issuance

`FastCheck.Tickets.Issuer.issue_order/2` is the approved ticket issuance boundary.

It:

- locks order using advisory transaction lock
- checks order/payment/checkout state
- creates or reuses attendees
- creates or reuses ticket issues
- bumps mobile sync
- marks order ticket-issued

VS-24A must not change or duplicate this.

### Scanner Authority

`FastCheck.Attendees.Scan` and the `Attendee` row own scanner acceptance and scanner-visible validity.

ArtifactResolver must mirror the existing TicketPage scanner-display eligibility:

- `TicketIssue.status` must be `issued`.
- Delivery token context must verify.
- Attendee must exist.
- Event must exist and not be archived.
- `Attendee.scan_eligibility` must allow scanning.
- `Attendee.payment_status` must be accepted by the existing TicketPage payment-status logic.

Do not use `TicketIssue.scanner_status` as scanner authority.

### Revocation Authority

`FastCheck.Tickets.Revocation` owns ticket revocation and scanner visibility invalidation.

VS-24A must not change revocation/refund behavior.

### Delivery Authority

`FastCheck.Workers.SendWhatsAppTicketLinkWorker` owns WhatsApp ticket-link delivery.

VS-24A must not rotate tokens, enqueue delivery jobs, send WhatsApp messages, or create delivery attempts.

## 4. Architecture Proposal

### New Modules

Create:

```text
lib/fastcheck/tickets/artifact.ex
lib/fastcheck/tickets/artifact_error.ex
lib/fastcheck/tickets/artifact_resolver.ex
test/fastcheck/tickets/artifact_resolver_test.exs
```

### Updated Modules

Update only as needed:

```text
lib/fastcheck/sales/ticket_page.ex
test/fastcheck/sales/ticket_page_test.exs
test/fastcheck_web/controllers/secure_ticket_controller_test.exs
```

### Documentation Files in Implementation PR

Add:

```text
docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/VS-24A-FEATURE_PACK.md
docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/pack.json
```

Do not add:

```text
docs/fastcheck_sales/handoffs/VS-24A_IMPLEMENTATION_HANDOFF.md
```

The handoff belongs in a separate post-merge docs-only PR after implementation.

### Boundary Rule

`FastCheck.Tickets.ArtifactResolver` answers exactly one question:

```text
Can this raw delivery token currently produce a customer-facing artifact safely?
```

It must not answer:

- Can this ticket enter the venue right now?
- Should a payment be accepted?
- Should a ticket be issued?
- Should a token be rotated?
- Should a WhatsApp delivery be sent?
- Should a refund/revocation happen?

## 5. Files to Create / Update

### Create

| Path | Purpose |
|---|---|
| `lib/fastcheck/tickets/artifact.ex` | Safe artifact struct. |
| `lib/fastcheck/tickets/artifact_error.ex` | Safe non-renderable result struct. |
| `lib/fastcheck/tickets/artifact_resolver.ex` | Read-only delivery-token-to-artifact resolver. |
| `test/fastcheck/tickets/artifact_resolver_test.exs` | Resolver behavior and privacy tests. |
| `docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/VS-24A-FEATURE_PACK.md` | Feature pack documentation. |
| `docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/pack.json` | Feature pack metadata. |

### Update

| Path | Expected Change |
|---|---|
| `lib/fastcheck/sales/ticket_page.ex` | Convert to adapter over `ArtifactResolver`; preserve return shape exactly. |
| `test/fastcheck/sales/ticket_page_test.exs` | Lock legacy shape and `qr_payload` mapping. |
| `test/fastcheck_web/controllers/secure_ticket_controller_test.exs` | Keep route/template behavior green; add regression only if needed. |
| Feature-pack indexes/manifests | Run repo sync/check script if convention requires it. |

### Do Not Create / Update

| Path / Area | Reason |
|---|---|
| `docs/fastcheck_sales/handoffs/VS-24A_IMPLEMENTATION_HANDOFF.md` | Post-merge handoff only. |
| Secure ticket controller | Behavior and route must remain stable. |
| Secure ticket HEEx template | Existing result shape must remain stable. |
| Payment modules | Authority unchanged. |
| Issuer modules | Authority unchanged. |
| Scanner mutation modules | Authority unchanged. |
| WhatsApp delivery worker | Delivery unchanged. |
| Migrations | No persistence required. |

## 6. In Scope / Out of Scope

### In Scope

- Customer-safe `Artifact` struct.
- Customer-safe `ArtifactError` struct.
- Read-only `ArtifactResolver.resolve_from_delivery_token/1`.
- `TicketPage.resolve/1` adapter over the resolver.
- Legacy secure-page result shape preservation.
- Current QR/scanner payload compatibility via `QrPayload.build_for_scanner/1`.
- Privacy tests.
- No-mutation tests.
- Focused docs/metadata for feature pack `0045_VS-24A`.

### Out of Scope

- PDF generation.
- Apple Wallet pass generation.
- Google Wallet pass generation.
- Wallet signing/certificates.
- New routes.
- Artifact persistence.
- Delivery token rotation.
- WhatsApp delivery behavior.
- Scanner check-in/check-out behavior.
- Payment verification behavior.
- Ticket issuance behavior.
- Revocation/refund behavior.
- Caches.
- Analytics.
- Handoff docs in the implementation PR.

## 7. Risks and Edge Cases

### Primary Risk

The main risk is accidentally changing the secure ticket page while extracting the artifact contract.

Mitigation:

- Do not change controller/template.
- Preserve `TicketPage.resolve/1` public map shape.
- Keep `qr_payload` as the legacy secure-page field.
- Lock with tests.

### Edge Case Matrix

| Case | Expected ArtifactResolver Result | Legacy TicketPage State |
|---|---|---|
| malformed token | `{:error, :not_found}` | `:not_found` |
| unknown token hash | `{:error, :not_found}` | `:not_found` |
| expired delivery token | `{:error, :expired_link}` | `:expired_link` |
| revoked ticket issue | `{:error, :ticket_revoked}` | `:ticket_revoked` |
| non-issued ticket issue | `{:error, :ticket_not_ready}` | `:ticket_not_ready` |
| missing attendee | safe error | existing-equivalent safe state |
| missing event | safe error | existing-equivalent safe state |
| archived event | `{:error, :ticket_not_ready}` | `:ticket_not_ready` |
| attendee not scannable | `{:error, :ticket_not_scannable}` | `:ticket_not_scannable` |
| unacceptable payment status | `{:error, :ticket_not_scannable}` | `:ticket_not_scannable` |
| valid issued ticket | `{:ok, %Artifact{}}` | `:valid` with `qr_payload` |

### Failure Modes to Avoid

- leaking token material through struct fields or inspect output
- leaking emails/phones through artifact fields
- treating `TicketIssue.scanner_status` as scanner authority
- changing QR format
- changing secure-page route/template/controller
- adding caches that make revocation stale
- creating handoff docs before merge
- adding wallet/PDF renderer code prematurely

## 8. Performance and Scaling Review

### Data Layer Classification

| Data | Layer | Rule |
|---|---|---|
| Raw delivery token | request-local only | Never persist, log, cache, or expose. |
| Delivery token hash lookup | Postgres cold source | Use existing unique delivery-token-hash lookup/index. |
| TicketIssue | Postgres cold source | Fetch one row only. |
| Attendee | Postgres cold source | Fetch linked row only. |
| Event | Postgres cold source | Fetch linked event only. |
| Artifact result | request-local hot value | Build and discard. No Redis/Cachex in VS-24A. |

### Caching Decision

Do **not** add Redis, Cachex, ETS, or browser caching in VS-24A.

Reason: artifact validity is sensitive to revocation, expiry, payment/scanner eligibility, and event archive status. A naive cache creates stale valid artifacts after revocation.

Future renderers may add tightly scoped caching only if they define:

- key shape with no raw token
- very short TTL
- revocation invalidation
- event archive invalidation
- attendee scanner eligibility invalidation
- delivery-token expiry invalidation
- cache-stampede protection

### Query Rules

Resolver flow must remain bounded:

1. Validate token format in memory.
2. Hash token using `TokenHash.hash(token, :delivery)`.
3. Fetch one `TicketIssue` by delivery-token hash.
4. Verify delivery context.
5. Fetch one linked `Attendee`.
6. Fetch one linked `Event` through order/event linkage.
7. Build safe artifact.

Do not load collections. Do not scan tables. Do not call external systems.

### Scaling Safety

VS-24A is safe under high read concurrency because:

- no write locks
- no external calls
- no Oban enqueue
- no long transactions
- no N+1 collection loading
- no cache invalidation complexity introduced

It does not itself solve flash-sale queuing or scanner concurrency. Those remain in existing sales/scanner slices.

## 9. Security and Privacy Review

### Public Artifact Field Rule

Allowed values must be safe display scalars only:

```text
state
event_name
attendee_name
ticket_type
scanner_payload
scanner_payload_format
support_message
issued_at
delivery_expires_at
```

`scanner_payload` is still sensitive enough to show only when the token is valid and current. It must be omitted/nil for all error states.

### Forbidden Fields

Never include:

```text
delivery_token
delivery_token_hash
qr_token_hash
ticket_url
payment_url
provider_payload
provider_message_body
provider_request_body
authorization_url
access_code
phone
email
recipient
```

### Inspect Redaction Rule

Because current scanner compatibility requires `scanner_payload` to be the plain ticket code, the new artifact structs must be safe when logs or test failures inspect them.

Required behavior:

- `artifact.scanner_payload` is present for valid artifacts.
- `inspect(artifact)` does not contain `artifact.scanner_payload`.
- `inspect(error)` contains no token, hash, ID, raw payload, phone, email, payment URL, ticket URL, or scanner payload.
- Do not rely on default struct inspection for `FastCheck.Tickets.Artifact` or `FastCheck.Tickets.ArtifactError`.

### Logging Rule

Do not log the raw token or token-derived URL. Existing secure-ticket tests should continue proving filtered route logging.

### Authorization Rule

The artifact resolver is possession-based for delivery tokens. Do not add dashboard or mobile scanner auth to `/t/:token`.

Do not add a resolver by `ticket_issue_id`, `attendee_id`, phone, or email in VS-24A.

## 10. Test Plan

### New Resolver Tests

Create:

```text
test/fastcheck/tickets/artifact_resolver_test.exs
```

Cover:

- valid token returns `%FastCheck.Tickets.Artifact{}`
- valid artifact exposes `artifact.scanner_payload` as a normal field
- `inspect(artifact)` does not contain `artifact.scanner_payload`
- `inspect(error)` contains no token, hash, ID, raw payload, phone, email, payment URL, ticket URL, or scanner payload
- artifact includes safe fields only
- artifact uses `scanner_payload_format: :plain_ticket_code`
- artifact uses `QrPayload.build_for_scanner(ticket_issue.ticket_code)`
- invalid token returns `:not_found`
- unknown token returns `:not_found`
- expired token returns `:expired_link`
- revoked ticket returns `:ticket_revoked`
- non-issued ticket returns `:ticket_not_ready`
- archived event returns `:ticket_not_ready`
- not-scannable attendee returns `:ticket_not_scannable`
- unacceptable payment returns `:ticket_not_scannable`
- resolver does not mutate TicketIssue, Attendee, Order, DeliveryAttempt, or payment rows
- `inspect/1` of artifact/error does not contain forbidden sensitive values

### TicketPage Adapter Tests

Update or add focused tests proving:

- `TicketPage.resolve/1` still returns map with exactly these public keys:
  - `state`
  - `event_name`
  - `attendee_name`
  - `ticket_type`
  - `qr_payload`
  - `support_message`
- valid legacy `qr_payload` equals `Artifact.scanner_payload`
- invalid states return nil display fields and safe support message
- current secure-page behavior remains unchanged

### Controller Regression Tests

Keep existing secure controller tests green.

Add only narrow regressions if current coverage does not prove:

- no controller change
- no template change
- valid ticket code rendered only for valid state
- invalid/expired/revoked/not-ready/not-scannable states do not render ticket code
- private no-store headers remain unchanged

### E2E Regression Tests

Run existing launch truth tests:

```text
test/fastcheck/sales/e2e/checkout_to_scanner_test.exs
test/fastcheck/sales/e2e/revocation_scanner_visibility_test.exs
```

## 11. Verification Commands

Run:

```bash
mix format
mix test test/fastcheck/tickets/artifact_resolver_test.exs
mix test test/fastcheck/sales/ticket_page_test.exs
mix test test/fastcheck_web/controllers/secure_ticket_controller_test.exs
mix test test/fastcheck/sales/e2e/checkout_to_scanner_test.exs
mix test test/fastcheck/sales/e2e/revocation_scanner_visibility_test.exs
mix precommit
```

If repo convention requires feature-pack indexes/manifests, run the repo sync/check script after adding docs.

## 12. TOON Scaffolding Prompt

| Field | Content |
|---|---|
| Task | Implement VS-24A — Ticket Artifact Domain Contract as one feature slice. |
| Objective | Create one shared, renderer-neutral, customer-safe artifact boundary that future PDF, Apple Wallet, and Google Wallet renderers can consume without duplicating payment, issuer, scanner, revocation, delivery, or secure-page logic. |
| Output | Create `lib/fastcheck/tickets/artifact.ex`, `lib/fastcheck/tickets/artifact_error.ex`, `lib/fastcheck/tickets/artifact_resolver.ex`, `test/fastcheck/tickets/artifact_resolver_test.exs`, `docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/VS-24A-FEATURE_PACK.md`, and `docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/pack.json`. Update `lib/fastcheck/sales/ticket_page.ex` and focused tests only. |
| Note | Before coding inspect current main. `0044` is already used by VS-22, so use `0045` unless the repo index script generates a different next number. Do not add `docs/fastcheck_sales/handoffs/VS-24A_IMPLEMENTATION_HANDOFF.md` in this PR. Preserve `TicketPage.resolve/1` public result shape with `qr_payload`. Do not change `SecureTicketController` or `secure_ticket_html/show.html.heex`. Use `QrPayload.build_for_scanner/1`. Keep scanner authority on Attendee/mobile scanner eligibility, not `TicketIssue.scanner_status`. No PDF, Apple Wallet, Google Wallet, routes, persistence, migrations, delivery changes, token rotation changes, caches, or external calls. Required index: existing unique delivery-token-hash lookup. Cache rule: none in VS-24A. TTL strategy: honor persisted delivery token expiry only. Redis structure: none. Invalidation: not applicable because no cache. PubSub: none. |

## 13. Granular TOON Micro-Prompts

### Group: Repo Truth / Numbering

| Field | Content |
|---|---|
| Task | Confirm the next feature-pack folder number before making docs changes. |
| Objective | Prevent pack ID collision with existing `0044_VS-22_end-to-end-sandbox-tests`. |
| Output | Use `docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/` unless the repo index sync/check script indicates a different next number. |
| Note | Run the repo’s feature-pack index sync/check script if present. Do not reuse `0044`. If generated metadata differs, follow repo truth and update pack metadata consistently. No code changes in this task. |

### Group: Contract Structs

| Field | Content |
|---|---|
| Task | Create the customer-safe artifact struct. |
| Objective | Provide one renderer-neutral contract for secure web, future PDF, future Apple Wallet, and future Google Wallet consumers. |
| Output | `lib/fastcheck/tickets/artifact.ex` with a simple typed struct using only `state`, `event_name`, `attendee_name`, `ticket_type`, `scanner_payload`, `scanner_payload_format`, `support_message`, `issued_at`, and `delivery_expires_at`. |
| Note | Do not include raw source structs, IDs, token hashes, QR token hashes, ticket URLs, payment URLs, Paystack values, provider payloads, phones, emails, or recipients. `scanner_payload_format` must support current value `:plain_ticket_code`. Implement custom `Inspect`: `inspect(artifact)` must redact `scanner_payload` and must not contain ticket codes, tokens, hashes, IDs, URLs, phones, emails, or provider/payment values. Keep `scanner_payload` available as a normal field for valid renderers. No DB calls, no cache, no external calls. |

| Field | Content |
|---|---|
| Task | Create the customer-safe artifact error struct. |
| Objective | Represent non-renderable ticket states without exposing sensitive internals. |
| Output | `lib/fastcheck/tickets/artifact_error.ex` with a simple typed struct using only `state`, `support_message`, and `http_status_hint`. |
| Note | Allowed states: `:not_found`, `:expired_link`, `:ticket_revoked`, `:ticket_not_scannable`, `:ticket_not_ready`. Implement custom `Inspect`: `inspect(error)` must contain no token, hash, ID, raw payload, phone, email, payment URL, ticket URL, or scanner payload. Do not include source structs, PII, provider payloads, or debug internals. Keep error messages generic and consistent with current TicketPage behavior. |

### Group: Resolver

| Field | Content |
|---|---|
| Task | Implement `FastCheck.Tickets.ArtifactResolver.resolve_from_delivery_token/1`. |
| Objective | Move current secure ticket-page validity policy into a renderer-neutral read-only boundary. |
| Output | `lib/fastcheck/tickets/artifact_resolver.ex` returning `{:ok, %FastCheck.Tickets.Artifact{}}` or `{:error, %FastCheck.Tickets.ArtifactError{}}`. |
| Note | Mirror existing `TicketPage` behavior: validate token format, hash with `TokenHash.hash(token, :delivery)`, fetch one `TicketIssue` by delivery token hash, verify `DeliveryToken.verify_context/2`, require `TicketIssue.status == "issued"`, load Attendee, load Event, reject archived event, require `Attendee.scan_eligibility` to allow scanning, and apply existing TicketPage payment-status acceptance. Build `scanner_payload` only with `FastCheck.Tickets.QrPayload.build_for_scanner(ticket_issue.ticket_code)`. Do not use `TicketIssue.scanner_status` as scanner authority. Do not mutate, rotate tokens, enqueue jobs, send WhatsApp, call Paystack, write audit rows, cache, or expose private fields. Existing index: delivery-token-hash unique lookup. TTL: persisted delivery token expiry. Redis: none. PubSub: none. |

### Group: TicketPage Adapter

| Field | Content |
|---|---|
| Task | Refactor `FastCheck.Sales.TicketPage.resolve/1` to consume `ArtifactResolver` internally. |
| Objective | Keep the secure ticket page stable while making it the first consumer of the shared artifact contract. |
| Output | Updated `lib/fastcheck/sales/ticket_page.ex` preserving the existing public map shape: `state`, `event_name`, `attendee_name`, `ticket_type`, `qr_payload`, and `support_message`. |
| Note | Map `artifact.scanner_payload` to legacy `qr_payload`. Do not change `FastCheckWeb.SecureTicketController`. Do not change `lib/fastcheck_web/controllers/secure_ticket_html/show.html.heex`. Do not add new keys required by the template. Invalid states must keep nil display fields and safe support messages. No cache, no writes, no route changes. |

### Group: Tests

| Field | Content |
|---|---|
| Task | Add focused resolver tests for valid and invalid artifact states. |
| Objective | Prove the new resolver exactly mirrors current secure-ticket eligibility and privacy behavior. |
| Output | `test/fastcheck/tickets/artifact_resolver_test.exs`. |
| Note | Cover valid, malformed, unknown, expired, revoked, non-issued, archived event, missing/invalid attendee path if feasible, not-scannable attendee, unacceptable payment, no-mutation behavior, safe fields only, and `inspect/1` not leaking forbidden values. Assert `artifact.scanner_payload` is present for valid artifacts, `inspect(artifact)` does not contain `artifact.scanner_payload`, and `inspect(error)` contains no token, hash, ID, raw payload, phone, email, payment URL, ticket URL, or scanner payload. Assert valid `scanner_payload == QrPayload.build_for_scanner(ticket_issue.ticket_code)` and `scanner_payload_format == :plain_ticket_code`. No PDF/wallet tests. |

| Field | Content |
|---|---|
| Task | Add or update TicketPage adapter regression tests. |
| Objective | Prove current secure-page public result shape remains unchanged after introducing ArtifactResolver. |
| Output | Updated `test/fastcheck/sales/ticket_page_test.exs` or equivalent existing TicketPage test file. |
| Note | Assert result keys remain `state`, `event_name`, `attendee_name`, `ticket_type`, `qr_payload`, and `support_message`. Assert artifact scanner payload maps to `qr_payload`. Assert invalid states do not expose a scanner/ticket payload. Do not require controller/template changes. |

| Field | Content |
|---|---|
| Task | Keep secure ticket controller regressions green. |
| Objective | Ensure `/t/:token` behavior remains unchanged for customers and launch E2E flows. |
| Output | Existing `test/fastcheck_web/controllers/secure_ticket_controller_test.exs` remains passing; add narrow regression only if existing coverage is insufficient. |
| Note | Do not change `SecureTicketController` or HEEx template. Ensure valid ticket code renders only for valid state, invalid states do not render ticket code, private no-store headers remain, rate-limit/log filtering still hides raw route tokens. |

### Group: Docs / Metadata

| Field | Content |
|---|---|
| Task | Add VS-24A feature-pack docs and metadata only under the feature-packs directory. |
| Objective | Keep planning docs aligned with repo pack conventions without creating premature post-merge handoffs. |
| Output | `docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/VS-24A-FEATURE_PACK.md` and `docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/pack.json`. |
| Note | Do not add `docs/fastcheck_sales/handoffs/VS-24A_IMPLEMENTATION_HANDOFF.md` in this implementation PR. If the repo has pack index/manifest sync, run it and commit generated index changes. Include required index note for delivery-token-hash lookup, cache strategy `none`, Redis structures `none`, invalidation `not applicable`, PubSub `none`, and future consumers PDF/Apple Wallet/Google Wallet as out-of-scope. |

### Group: Verification

| Field | Content |
|---|---|
| Task | Run focused and repo-standard verification commands. |
| Objective | Prove the artifact boundary preserves launch behavior and does not break secure-ticket, scanner, revocation, or E2E flows. |
| Output | Passing command output for focused tests and `mix precommit`; note any environment-only failures explicitly. |
| Note | Run `mix format`, resolver tests, TicketPage tests, secure controller tests, VS-22 checkout-to-scanner E2E, VS-22 revocation scanner visibility E2E, and `mix precommit`. Do not skip E2E unless blocked by missing local secrets; if blocked, state exact missing dependency. |

## What Success Looks Like

- `FastCheck.Tickets.ArtifactResolver` exists and is read-only.
- Valid delivery token resolves to one safe `%FastCheck.Tickets.Artifact{}`.
- Secure web page still receives `qr_payload` through `FastCheck.Sales.TicketPage.resolve/1`.
- `SecureTicketController` is unchanged.
- `secure_ticket_html/show.html.heex` is unchanged.
- Scanner payload is built with `QrPayload.build_for_scanner/1`.
- Scanner-display authority mirrors Attendee/mobile scanner eligibility and current TicketPage payment-status logic.
- `TicketIssue.scanner_status` is not used as artifact scanner authority.
- Invalid/expired/revoked/not-ready/not-scannable states never expose a ticket code/scanner payload.
- No PDF, Apple Wallet, Google Wallet, route, persistence, migration, delivery, token rotation, payment, issuer, scanner, or revocation changes exist.
- No handoff file is added in the implementation PR.
- Focused tests and `mix precommit` pass.
