# VS-24A — TOON Prompt Set

## Scaffolding

| Field | Content |
|---|---|
| Task | Implement VS-24A — Ticket Artifact Domain Contract as one feature slice. |
| Objective | Create one shared, renderer-neutral, customer-safe artifact boundary that future PDF, Apple Wallet, and Google Wallet renderers can consume without duplicating payment, issuer, scanner, revocation, delivery, or secure-page logic. |
| Output | Create `lib/fastcheck/tickets/artifact.ex`, `lib/fastcheck/tickets/artifact_error.ex`, `lib/fastcheck/tickets/artifact_resolver.ex`, `test/fastcheck/tickets/artifact_resolver_test.exs`, `docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/VS-24A-FEATURE_PACK.md`, and `docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/pack.json`. Update `lib/fastcheck/sales/ticket_page.ex` and focused tests only. |
| Note | Before coding inspect current main. `0044` is already used by VS-22, so use `0045` unless the repo index script generates a different next number. Do not add `docs/fastcheck_sales/handoffs/VS-24A_IMPLEMENTATION_HANDOFF.md` in this PR. Preserve `TicketPage.resolve/1` public result shape with `qr_payload`. Do not change `SecureTicketController` or `secure_ticket_html/show.html.heex`. Implement custom `Inspect` redaction for `Artifact` and `ArtifactError`; default struct inspection is not allowed because `scanner_payload` is currently the plain scanner ticket code. Use `QrPayload.build_for_scanner/1`. Keep scanner authority on Attendee/mobile scanner eligibility, not `TicketIssue.scanner_status`. No PDF, Apple Wallet, Google Wallet, routes, persistence, migrations, delivery changes, token rotation changes, caches, or external calls. Required index: existing unique delivery-token-hash lookup. Cache rule: none in VS-24A. TTL strategy: honor persisted delivery token expiry only. Redis structure: none. Invalidation: not applicable because no cache. PubSub: none. |

## Contract Structs

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

## Resolver

| Field | Content |
|---|---|
| Task | Implement `FastCheck.Tickets.ArtifactResolver.resolve_from_delivery_token/1`. |
| Objective | Move current secure ticket-page validity policy into a renderer-neutral read-only boundary. |
| Output | `lib/fastcheck/tickets/artifact_resolver.ex` returning `{:ok, %FastCheck.Tickets.Artifact{}}` or `{:error, %FastCheck.Tickets.ArtifactError{}}`. |
| Note | Mirror existing `TicketPage` behavior: validate token format, hash with `TokenHash.hash(token, :delivery)`, fetch one `TicketIssue` by delivery token hash, verify `DeliveryToken.verify_context/2`, require `TicketIssue.status == "issued"`, load Attendee, load Event, reject archived event, require `Attendee.scan_eligibility` to allow scanning, and apply existing TicketPage payment-status acceptance. Build `scanner_payload` only with `FastCheck.Tickets.QrPayload.build_for_scanner(ticket_issue.ticket_code)`. Do not use `TicketIssue.scanner_status` as scanner authority. Do not mutate, rotate tokens, enqueue jobs, send WhatsApp, call Paystack, write audit rows, cache, or expose private fields. Existing index: delivery-token-hash unique lookup. TTL: persisted delivery token expiry. Redis: none. PubSub: none. |

## TicketPage Adapter

| Field | Content |
|---|---|
| Task | Refactor `FastCheck.Sales.TicketPage.resolve/1` to consume `ArtifactResolver` internally. |
| Objective | Keep the secure ticket page stable while making it the first consumer of the shared artifact contract. |
| Output | Updated `lib/fastcheck/sales/ticket_page.ex` preserving the existing public map shape: `state`, `event_name`, `attendee_name`, `ticket_type`, `qr_payload`, and `support_message`. |
| Note | Map `artifact.scanner_payload` to legacy `qr_payload`. Do not change `FastCheckWeb.SecureTicketController`. Do not change `lib/fastcheck_web/controllers/secure_ticket_html/show.html.heex`. Do not add new keys required by the template. Invalid states must keep nil display fields and safe support messages. No cache, no writes, no route changes. |

## Tests

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

## Docs / Metadata

| Field | Content |
|---|---|
| Task | Add VS-24A feature-pack docs and metadata only under the feature-packs directory. |
| Objective | Keep planning docs aligned with repo pack conventions without creating premature post-merge handoffs. |
| Output | `docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/VS-24A-FEATURE_PACK.md` and `docs/fastcheck_sales/feature_packs/0045_VS-24A_ticket-artifact-domain-contract/pack.json`. |
| Note | Do not add `docs/fastcheck_sales/handoffs/VS-24A_IMPLEMENTATION_HANDOFF.md` in this implementation PR. If the repo has pack index/manifest sync, run it and commit generated index changes. Include required index note for delivery-token-hash lookup, cache strategy `none`, Redis structures `none`, invalidation `not applicable`, PubSub `none`, and future consumers PDF/Apple Wallet/Google Wallet as out-of-scope. |

## Verification

| Field | Content |
|---|---|
| Task | Run focused and repo-standard verification commands. |
| Objective | Prove the artifact boundary preserves launch behavior and does not break secure-ticket, scanner, revocation, or E2E flows. |
| Output | Passing command output for focused tests and `mix precommit`; note any environment-only failures explicitly. |
| Note | Run `mix format`, resolver tests, TicketPage tests, secure controller tests, VS-22 checkout-to-scanner E2E, VS-22 revocation scanner visibility E2E, and `mix precommit`. Do not skip E2E unless blocked by missing local secrets; if blocked, state exact missing dependency. |
