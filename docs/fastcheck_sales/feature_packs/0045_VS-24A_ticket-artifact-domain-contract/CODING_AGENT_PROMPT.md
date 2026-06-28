# Coding-Agent Prompt — VS-24A Ticket Artifact Domain Contract

## Mission

Implement **VS-24A — Ticket Artifact Domain Contract** in `JCSchoeman96/FastCheckin`.

Implement VS-24A only.

Before coding:

- Fix/confirm the feature-pack folder/pack ID so it does not reuse `0044`.
- Use `0045_VS-24A_ticket-artifact-domain-contract` unless the repo index sync/check script generates a different next number.
- Do not add `docs/fastcheck_sales/handoffs/VS-24A_IMPLEMENTATION_HANDOFF.md` in this implementation PR.
- Preserve `FastCheck.Sales.TicketPage.resolve/1` public result shape.
- Do not change `FastCheckWeb.SecureTicketController`.
- Do not change `lib/fastcheck_web/controllers/secure_ticket_html/show.html.heex`.
- Use `FastCheck.Tickets.ArtifactResolver` internally from `TicketPage`.
- Map `Artifact.scanner_payload` to the legacy `qr_payload` field.
- Build scanner payload using `FastCheck.Tickets.QrPayload.build_for_scanner/1`.
- Keep Attendee/mobile scanner eligibility as scanner authority.
- Do not use `TicketIssue.scanner_status` as artifact authority.
- Do not add PDF, Apple Wallet, Google Wallet, routes, persistence, migrations, delivery changes, or token rotation changes.
- Implement custom `Inspect` protocols for `FastCheck.Tickets.Artifact` and `FastCheck.Tickets.ArtifactError` so logs and test failures redact `scanner_payload` and any sensitive values.

## Ultimate Goal

Create the shared safe boundary that turns an issued, currently-valid ticket into a customer-facing artifact.

Future renderers must consume this shared artifact contract:

```text
Secure ticket page
PDF ticket
Apple Wallet pass
Google Wallet pass
```

Do not create four ticket systems.

## Hard Rules

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
- Do not create PDF, Apple Wallet, or Google Wallet code.
- Do not add migrations. Expected answer: no migration.
- Keep implementation minimal and clean.

## Current Repo Truth to Inspect First

Inspect these files before changing anything:

```text
lib/fastcheck_web/controllers/secure_ticket_controller.ex
lib/fastcheck_web/controllers/secure_ticket_html/show.html.heex
lib/fastcheck_web/router.ex
lib/fastcheck/sales/ticket_page.ex
lib/fastcheck/sales/ticket_issue.ex
lib/fastcheck/tickets/delivery_token.ex
lib/fastcheck/tickets/token_hash.ex
lib/fastcheck/tickets/qr_payload.ex
lib/fastcheck/tickets/issuer.ex
lib/fastcheck/tickets/revocation.ex
lib/fastcheck/tickets/scanner_visibility.ex
lib/fastcheck/attendees/scan.ex
lib/fastcheck/attendees/attendee.ex
lib/fastcheck/sales/delivery_attempt.ex
lib/fastcheck/workers/send_whatsapp_ticket_link_worker.ex
test/fastcheck_web/controllers/secure_ticket_controller_test.exs
test/fastcheck/sales/e2e/checkout_to_scanner_test.exs
test/fastcheck/sales/e2e/revocation_scanner_visibility_test.exs
docs/fastcheck_sales/handoffs/README.md
```

## Architecture to Implement

Create:

```text
lib/fastcheck/tickets/artifact.ex
lib/fastcheck/tickets/artifact_error.ex
lib/fastcheck/tickets/artifact_resolver.ex
test/fastcheck/tickets/artifact_resolver_test.exs
docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/VS-24A-FEATURE_PACK.md
docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/pack.json
```

Update:

```text
lib/fastcheck/sales/ticket_page.ex
test/fastcheck/sales/ticket_page_test.exs
test/fastcheck_web/controllers/secure_ticket_controller_test.exs
```

Do **not** create:

```text
docs/fastcheck_sales/handoffs/VS-24A_IMPLEMENTATION_HANDOFF.md
```

The handoff is a separate post-merge docs-only PR.

## Required Contract

### `FastCheck.Tickets.Artifact`

Create a simple typed struct.

Allowed fields:

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

Use `scanner_payload_format: :plain_ticket_code` for current scanner compatibility.

Because `scanner_payload` is currently the plain scanner ticket code, implement a custom `Inspect` protocol for this struct. The field must remain available to valid renderers as normal data, but `inspect(artifact)` must redact `scanner_payload` and must not print ticket codes, tokens, hashes, IDs, URLs, phones, emails, payment values, or provider payloads.

Do not include raw structs or sensitive fields.

### `FastCheck.Tickets.ArtifactError`

Create a simple typed struct.

Allowed fields:

```text
state
support_message
http_status_hint
```

Implement a custom `Inspect` protocol for this struct too. `inspect(error)` must stay generic and must not contain a token, token hash, ID, raw payload, phone, email, payment URL, ticket URL, or scanner payload.

Allowed states:

```text
:not_found
:expired_link
:ticket_revoked
:ticket_not_scannable
:ticket_not_ready
```

### `FastCheck.Tickets.ArtifactResolver`

Implement:

```text
resolve_from_delivery_token(raw_token)
```

Return:

```text
{:ok, %FastCheck.Tickets.Artifact{}}
{:error, %FastCheck.Tickets.ArtifactError{}}
```

The resolver must mirror the existing `TicketPage` scanner-display eligibility:

1. Trim and validate token format using current `TicketPage` rules.
2. Hash token with `TokenHash.hash(token, :delivery)`.
3. Fetch one `TicketIssue` by `:get_by_delivery_token_hash`.
4. Verify delivery context with `DeliveryToken.verify_context/2`.
5. Require `ticket_issue.status == "issued"`.
6. Load linked attendee.
7. Load linked event through sales order.
8. Reject archived event.
9. Ensure `Attendee.scan_eligibility` allows scanning.
10. Validate `Attendee.payment_status` using the existing `TicketPage` payment-status logic.
11. Build `scanner_payload` with `QrPayload.build_for_scanner(ticket_issue.ticket_code)`.
12. Return a safe artifact.

The resolver must not:

- use `TicketIssue.scanner_status` as scanner authority
- mutate rows
- rotate tokens
- enqueue Oban jobs
- send WhatsApp messages
- call Paystack
- call scanner mutation
- write audit records
- cache artifact results
- expose private fields

## TicketPage Adapter Requirement

`FastCheck.Sales.TicketPage.resolve/1` must preserve its existing public return shape for the secure ticket page.

It may call `FastCheck.Tickets.ArtifactResolver` internally, but it must still return a map with:

```text
state
event_name
attendee_name
ticket_type
qr_payload
support_message
```

Map:

```text
artifact.scanner_payload -> qr_payload
```

Do not change `SecureTicketController`.
Do not change `secure_ticket_html/show.html.heex`.

## Performance Rules

- No Redis/Cachex cache in VS-24A.
- No artifact persistence.
- No unbounded queries.
- Use existing delivery-token hash lookup path.
- Keep all work request-local.
- No remote calls.
- No analytics or dashboard aggregation.

## Security Rules

Forbidden in artifacts, errors, logs, HTML, telemetry, and tests:

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

Never embed:

```text
%TicketIssue{}
%Attendee{}
%Order{}
%DeliveryAttempt{}
%Conversation{}
```

Only copy safe scalar values.

### Inspect Redaction Requirement

Because `Artifact.scanner_payload` is currently the plain scanner ticket code, both new structs must define safe inspect behavior:

- `FastCheck.Tickets.Artifact` must redact `scanner_payload` from `inspect/1`.
- `FastCheck.Tickets.ArtifactError` must have a custom inspect shape that cannot leak tokens, hashes, IDs, raw payloads, phone numbers, emails, payment URLs, ticket URLs, or scanner payloads.
- Keep `artifact.scanner_payload` available as a normal field for valid renderers.
- Do not rely on default struct inspection for either new struct.

## TOON Micro-Prompts

### Scaffolding

| Field | Content |
|---|---|
| Task | Implement VS-24A — Ticket Artifact Domain Contract as one feature slice. |
| Objective | Create one shared, renderer-neutral, customer-safe artifact boundary that future PDF, Apple Wallet, and Google Wallet renderers can consume without duplicating payment, issuer, scanner, revocation, delivery, or secure-page logic. |
| Output | Create artifact modules, resolver tests, feature-pack docs under `0045_VS-24A_ticket-artifact-domain-contract`, and update `TicketPage` as adapter only. |
| Note | Do not reuse `0044`. Do not add handoff docs in this implementation PR. No routes, migrations, caches, PDF/wallet code, delivery changes, token rotation, payment changes, issuer changes, scanner changes, or revocation changes. |

### Contract Structs

| Field | Content |
|---|---|
| Task | Create `FastCheck.Tickets.Artifact`. |
| Objective | Provide a renderer-neutral safe artifact data contract. |
| Output | `lib/fastcheck/tickets/artifact.ex`. |
| Note | Fields only: `state`, `event_name`, `attendee_name`, `ticket_type`, `scanner_payload`, `scanner_payload_format`, `support_message`, `issued_at`, `delivery_expires_at`. Implement custom `Inspect` redaction: `inspect(artifact)` must not contain `scanner_payload`, ticket code, tokens, hashes, IDs, URLs, phones, emails, provider payloads, or Paystack values. Keep `scanner_payload` available as a normal field for valid renderers. |

| Field | Content |
|---|---|
| Task | Create `FastCheck.Tickets.ArtifactError`. |
| Objective | Represent non-renderable states safely. |
| Output | `lib/fastcheck/tickets/artifact_error.ex`. |
| Note | Fields only: `state`, `support_message`, `http_status_hint`. Allowed states: `:not_found`, `:expired_link`, `:ticket_revoked`, `:ticket_not_scannable`, `:ticket_not_ready`. Implement custom `Inspect` so `inspect(error)` contains no token, hash, ID, raw payload, phone, email, payment URL, ticket URL, or scanner payload. |

### Resolver

| Field | Content |
|---|---|
| Task | Implement `ArtifactResolver.resolve_from_delivery_token/1`. |
| Objective | Extract current `TicketPage` eligibility policy into a read-only artifact boundary. |
| Output | `lib/fastcheck/tickets/artifact_resolver.ex`. |
| Note | Use current token format validation, `TokenHash.hash(token, :delivery)`, `DeliveryToken.verify_context/2`, issued TicketIssue requirement, linked Attendee, linked Event, non-archived event, `Attendee.scan_eligibility`, and existing TicketPage payment-status logic. Build `scanner_payload` with `QrPayload.build_for_scanner(ticket_issue.ticket_code)`. Do not use `TicketIssue.scanner_status` as scanner authority. Cache: none. Redis: none. PubSub: none. Writes: none. |

### TicketPage Adapter

| Field | Content |
|---|---|
| Task | Refactor `TicketPage.resolve/1` to call `ArtifactResolver`. |
| Objective | Make the secure ticket page the first consumer without changing its public contract. |
| Output | Updated `lib/fastcheck/sales/ticket_page.ex`. |
| Note | Preserve map keys exactly: `state`, `event_name`, `attendee_name`, `ticket_type`, `qr_payload`, `support_message`. Map `Artifact.scanner_payload` to `qr_payload`. Do not change controller/template. |

### Tests

| Field | Content |
|---|---|
| Task | Add resolver tests. |
| Objective | Prove valid and invalid artifact states, no mutation, and no sensitive exposure. |
| Output | `test/fastcheck/tickets/artifact_resolver_test.exs`. |
| Note | Cover valid, malformed, unknown, expired, revoked, non-issued, archived, not-scannable, unacceptable payment, no mutation, safe fields, and inspect redaction/no leaks. Assert `scanner_payload == QrPayload.build_for_scanner(ticket_issue.ticket_code)` and format `:plain_ticket_code`. Assert `artifact.scanner_payload` is present for valid artifacts, `inspect(artifact)` does not contain that payload, and `inspect(error)` contains no token, hash, ID, raw payload, phone, email, payment URL, ticket URL, or scanner payload. |

| Field | Content |
|---|---|
| Task | Add TicketPage adapter regressions. |
| Objective | Ensure secure-page public result shape remains unchanged. |
| Output | Updated `test/fastcheck/sales/ticket_page_test.exs` or equivalent existing test file. |
| Note | Assert legacy keys and `qr_payload` mapping. Invalid states must not expose scanner payload/ticket code. |

### Docs / Metadata

| Field | Content |
|---|---|
| Task | Add feature-pack docs and metadata. |
| Objective | Keep implementation documentation aligned with repo pack conventions. |
| Output | Feature-pack docs under `docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/`. |
| Note | Do not add handoff docs in implementation PR. Run repo index/manifest sync/check script if present. |

### Verification

| Field | Content |
|---|---|
| Task | Run focused and repo-standard verification commands. |
| Objective | Prove secure-ticket, scanner, revocation, and E2E behavior remains stable. |
| Output | Passing focused tests and `mix precommit`; document any environment-only blockers. |
| Note | Run `mix format`, resolver tests, TicketPage tests, secure controller tests, VS-22 E2E checkout-to-scanner, VS-22 revocation scanner visibility, and `mix precommit`. |

## Tests to Add

Create `test/fastcheck/tickets/artifact_resolver_test.exs`.

Cover:

- valid token returns artifact
- invalid token returns `:not_found`
- expired token returns `:expired_link`
- revoked ticket returns `:ticket_revoked`
- non-issued ticket returns `:ticket_not_ready`
- not-scannable attendee returns `:ticket_not_scannable`
- non-completed payment returns `:ticket_not_scannable`
- archived event returns `:ticket_not_ready`
- resolver does not mutate rows
- valid artifact exposes `artifact.scanner_payload` as a normal field
- `inspect(artifact)` does not contain `artifact.scanner_payload`
- `inspect(error)` contains no token, hash, ID, raw payload, phone, email, payment URL, ticket URL, or scanner payload

Keep existing controller tests green.

## Verification Commands

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

## Definition of Done

- `ArtifactResolver` exists and is read-only.
- `TicketPage` consumes `ArtifactResolver`.
- Current secure ticket page behavior is unchanged.
- `TicketPage.resolve/1` still returns `qr_payload` for the secure page.
- `SecureTicketController` is unchanged.
- Secure ticket HEEx template is unchanged.
- No renderer-specific code exists.
- No migration exists.
- No authority boundary changed.
- No implementation handoff is added in the implementation PR.
- Privacy tests prove forbidden values are not exposed.
- Custom `Inspect` tests prove `Artifact` and `ArtifactError` do not leak scanner payloads or sensitive values in logs/test failures.
- Focused tests and `mix precommit` pass.
