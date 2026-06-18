# VS-08 Implementation Handoff

## Status

Merged.

PR: #372 — feat(tickets): VS-08 ticket code, QR, and delivery token foundation  
Merge commit: `44f93324b742650de138f65e4f5817734f9f7ecd`  
Merged at: 2026-06-18T20:00:49Z  
Branch: `vs-08-ticket-token-foundation`

## What Changed

VS-08 added pure Elixir ticket identifier and token security primitives under
`FastCheck.Tickets`. The slice provides DB-free ticket code generation,
purpose-bound HMAC token hashing (`:delivery` / `:qr`), scanner-compatible QR
payload helpers, delivery bearer token generation/verification, dedicated
`TICKET_TOKEN_PEPPER` config, and missing `sales_ticket_issues` token-hash/expiry
indexes.

A follow-up commit in the same PR made `DeliveryToken.verify_context/2` fail
closed when `delivery_token_expires_at` is missing or `nil`.

No ticket issuance, `TicketIssue` creation from orders, Attendee mutation,
scanner/mobile changes, payment/checkout/inventory mutation, or delivery/WhatsApp
behavior was added.

## Files Changed

- `lib/fastcheck/tickets/code_generator.ex` — DB-free `FC-` ticket code candidates
  (128-bit entropy, scanner-safe alphabet).
- `lib/fastcheck/tickets/token_hash.ex` — purpose-bound HMAC-SHA256 hashing and
  verification for `:delivery` and `:qr`.
- `lib/fastcheck/tickets/qr_payload.ex` — scanner QR build/parse; QR token hash
  helpers using `:qr`.
- `lib/fastcheck/tickets/delivery_token.ex` — delivery bearer token generate,
  verify, expiry/revocation context checks using `:delivery`.
- `lib/fastcheck/sales/ticket_issue.ex` — Ash identities for partial unique
  `qr_token_hash` and `delivery_token_hash` indexes only; no new actions.
- `priv/repo/migrations/20260618120000_add_ticket_token_indexes.exs` — token hash
  and expiry query-path indexes on `sales_ticket_issues`.
- `config/runtime.exs` — `TICKET_TOKEN_PEPPER` fail-closed in production.
- `config/test.exs` — test-only `:ticket_token_pepper`.
- `config/config.exs` — `:sales_delivery_token_ttl_seconds` default (90 days).
- `docs/fastcheck_sales/slices/VS-08_TICKET_CODE_QR_DELIVERY_TOKEN_FOUNDATION.md`
  — QR format decision, identifier model, deferred integration notes.
- `test/fastcheck/tickets/code_generator_test.exs` — entropy, format, scanner-safe
  alphabet.
- `test/fastcheck/tickets/token_hash_test.exs` — purpose separation and dedicated
  pepper config.
- `test/fastcheck/tickets/qr_payload_test.exs` — plain scanner payload, parse
  errors, no PII in payload.
- `test/fastcheck/tickets/delivery_token_test.exs` — generate bundle, expiry,
  revocation, missing-expiry fail-closed, cross-purpose rejection.
- `test/fastcheck/tickets/ticket_token_indexes_test.exs` — VS-08 index catalog
  and duplicate hash rejection.
- `test/fastcheck/tickets/ticket_token_security_test.exs` — log/metadata redaction
  for plaintext tokens.
- `test/fastcheck/tickets/ticket_token_boundary_test.exs` — no issuer/workers/
  scanner/mobile creep.
- `test/fastcheck/sales/vs_01f_boundary_test.exs` — allows VS-08 ticket modules;
  still forbids `Tickets.Issuer`.
- `test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs` — same
  forbidden-path update.
- `test/fastcheck/sales/core_resource_boundary_test.exs` — forbids `issuer.ex`
  only under `lib/fastcheck/tickets/`.
- `test/fastcheck/sales/ticket_offer_boundary_test.exs` — same issuer-only forbid.

## Contracts Now Available

- `FastCheck.Tickets.CodeGenerator.generate/0` returns one random `FC-` ticket
  code candidate without Repo calls.
- `FastCheck.Tickets.TokenHash.hash/2` and `verify/3` use HMAC-SHA256 with
  purpose prefixes `"delivery:"` and `"qr:"`.
- Dedicated config `:ticket_token_pepper` (`TICKET_TOKEN_PEPPER` in prod) is
  separate from `:sales_hold_token_pepper`.
- `FastCheck.Tickets.QrPayload.build_for_scanner/1` returns plain `ticket_code`
  for current scanner compatibility.
- `FastCheck.Tickets.DeliveryToken.generate/1` returns plaintext once plus hash
  and `expires_at`; `verify_context/2` returns `:ok` or
  `{:error, :invalid | :expired | :revoked}`.
- Missing or `nil` `delivery_token_expires_at` rejects verification (`:expired`).
- Migration `20260618120000_add_ticket_token_indexes.exs` adds:
  - `sales_ticket_issues_qr_token_hash_uidx`
  - `sales_ticket_issues_delivery_token_hash_uidx`
  - `sales_ticket_issues_delivery_token_expires_at_idx`
  - `sales_ticket_issues_status_delivery_token_expires_at_idx`
- `FastCheck.Sales.TicketIssue` registers Ash identities aligned to the new
  partial unique hash indexes.
- Historical Sales boundary tests allow VS-08 modules but still forbid
  `lib/fastcheck/tickets/issuer.ex`.

## Decisions Applied

- Three separate identifiers: `ticket_code`, `qr_token_hash`, `delivery_token_hash`.
- Purpose-bound hashing enforces delivery vs QR domain separation.
- Plaintext QR/delivery tokens are not persisted; only hashes and expiry metadata.
- Scanner release QR payload = plain `ticket_code` (no `FC1:` prefix on hot path).
- `event_scoped_first`; `organization_id` deferred.
- No Ash workflow actions on `TicketIssue`.
- No Redis token storage in this slice.
- Reuse `FastCheck.Observability.Redactor` for token log safety in tests.

## Boundaries Still Enforced

- No `FastCheck.Tickets.Issuer`.
- No `TicketIssue` creation from paid orders.
- No Attendee creation or mutation.
- No scanner, Android, or mobile API changes.
- No secure ticket page controller, `DeliveryAttempt` workers, or WhatsApp/email.
- No Paystack, order, checkout, payment, or inventory state mutation.
- No admin/customer UI.

## Tests Added Or Updated

- `test/fastcheck/tickets/*` — seven new files covering generators, purpose-bound
  hashing, QR payload rules, delivery token lifecycle, indexes, security
  redaction, and VS-08 boundary guards.
- `test/fastcheck/sales/vs_01f_boundary_test.exs` — VS-08 modules no longer
  forbidden.
- `test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs` — same.
- `test/fastcheck/sales/core_resource_boundary_test.exs` — issuer-only forbid.
- `test/fastcheck/sales/ticket_offer_boundary_test.exs` — issuer-only forbid.

## Verification Reported

PR #372 body and implementation verification:

```bash
mix test test/fastcheck/tickets/
mix test test/fastcheck/sales/
mix precommit
```

Results reported at merge:

- `mix test test/fastcheck/tickets/` — 26 tests, 0 failures (includes missing-expiry patch)
- `mix precommit` — 716 tests, 0 failures, 4 skipped
- GitHub CI `Test (Elixir 1.17.3 OTP 26.2)` for PR #372 — pass

Production deploy must set `TICKET_TOKEN_PEPPER` separately from
`SALES_HOLD_TOKEN_PEPPER`.

## Known Limitations

- Primitives only: no issuance orchestration, no TicketIssue rows from orders.
- `DeliveryToken.rotate/1` returns a new bundle; persistence belongs to later slices.
- `FC1:` QR parsing exists for forward compatibility but is not used on the
  current scanner hot path.
- Secure ticket page hash lookup, rate limiting, and cache invalidation belong to
  VS-11 and later slices.
- Token rotation/revocation persistence and scanner bridge belong to VS-09B/C/D
  and VS-15A.

## Next Agent Guidance

**Reuse:**

- `FastCheck.Tickets.CodeGenerator`, `TokenHash`, `QrPayload`, `DeliveryToken`
  for all Sales ticket identifier work.
- `:ticket_token_pepper` and purpose-bound hashing; do not reuse hold-token pepper.
- Existing `sales_ticket_issues` token columns and VS-08 indexes.
- `QrPayload.build_for_scanner/1` until scanner contract is formally changed.

**Do not:**

- Recreate token hashing or ticket code rules in issuance or secure-page slices.
- Store plaintext `delivery_token` or `qr_token` in Postgres or logs.
- Add `Tickets.Issuer` or issue tickets before VS-09A contract is implemented.
- Bypass missing-expiry fail-closed behavior in `verify_context/2`.

**Keep green:**

- `test/fastcheck/tickets/`
- `test/fastcheck/sales/vs_01f_boundary_test.exs`
- `test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs`
- prior Sales skeleton, migration, policy, and payment tests

## Next Slice

Recommended next slice: **VS-09A — Ticket Issuance Contract and Idempotency Model**

Entry condition: VS-08 must remain merged and accepted. Read this handoff, the
VS-01D handoff, and the VS-09A feature pack before defining issuance contracts.
Reuse VS-08 primitives for codes and tokens; do not change scanner behavior or
issue tickets without the VS-09A idempotency model.
