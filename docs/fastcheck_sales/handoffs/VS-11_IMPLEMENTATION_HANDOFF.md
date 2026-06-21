# VS-11 Implementation Handoff

## Status

Merged.

PR: #385 — feat(sales): VS-11 secure ticket page  
Merge commit: `6726b75a5dfae95582b9cfc798622b380e0e6637`  
Merged at: 2026-06-21T14:40:40Z  
Branch: `cursor/vs-11-secure-ticket-page`

## What Changed

VS-11 added the public read-only customer secure ticket page at `GET /t/:token`.
A possession-based delivery bearer token is hashed and looked up against
`FastCheck.Sales.TicketIssue`; linked Attendee and Event display data is loaded
safely; and a scanner-compatible text payload is rendered only when the ticket
is fully valid.

The slice added `FastCheck.Sales.TicketPage.resolve/1` as the sole domain
classification boundary, a narrow Ash read action on `TicketIssue`, browser
controller/HEEx rendering, no-store/private/noindex response headers, `/t/`
rate limiting with sanitized logging/telemetry, and mandatory Redactor hardening
for `/t/<opaque-token>` URLs.

No delivery, payment, issuance, scanner, mobile sync, Android, Redis, migration,
or handoff-doc behavior was added in the implementation PR.

## Files Changed

- `lib/fastcheck/sales/ticket_page.ex` — read-only domain boundary;
  `resolve/1` classifies tokens into customer-safe display states and returns
  only approved fields (`qr_payload` only when `state == :valid`).
- `lib/fastcheck/sales/ticket_issue.ex` — adds Ash read action
  `:get_by_delivery_token_hash` for indexed hash lookup.
- `lib/fastcheck_web/controllers/secure_ticket_controller.ex` — public HTTP
  entrypoint; sets cache/robots headers; maps states to HTTP status.
- `lib/fastcheck_web/controllers/secure_ticket_html.ex` — HEEx module shell.
- `lib/fastcheck_web/controllers/secure_ticket_html/show.html.heex` — customer
  page template; ticket code text only in the valid-state branch.
- `lib/fastcheck_web/router.ex` — registers `GET /t/:token` in the public
  `:browser` scope (no dashboard/scanner auth).
- `lib/fastcheck_web/plugs/rate_limiter.ex` — `/t/` throttle rule
  (`secure_ticket_limit`, default 5/min via `get_limit/2`); blocked-request logs
  and telemetry use sanitized path `/t/[FILTERED]`.
- `lib/fastcheck/observability/redactor.ex` — filters `/t/<opaque-token>` paths
  and full URLs.
- `test/fastcheck/sales/ticket_page_test.exs` — domain classification, safe
  reads, no payload on invalid states, no sensitive fields in result.
- `test/fastcheck_web/controllers/secure_ticket_controller_test.exs` — public
  route, headers, rate-limit sanitization, no code leak on invalid states, no
  row mutation.
- `test/fastcheck/observability/redactor_test.exs` — `/t/` URL redaction cases.
- `test/fastcheck/sales/domain_shell_test.exs` — Sales file inventory includes
  `ticket_page.ex`.

## Contracts Now Available

- `FastCheck.Sales.TicketPage.resolve/1` is the authoritative customer ticket
  page classification entrypoint.
- Result shape:

  ```elixir
  %{
    state: :valid | :not_found | :expired_link | :ticket_revoked |
           :ticket_not_scannable | :ticket_not_ready,
    event_name: nil | String.t(),
    attendee_name: nil | String.t(),
    ticket_type: nil | String.t(),
    qr_payload: nil | String.t(),
    support_message: String.t()
  }
  ```

- Malformed/blank tokens return `:not_found` before DB lookup.
- Token verification uses VS-08 `TokenHash.hash/2` (`:delivery`) and
  `DeliveryToken.verify_context/2`.
- `qr_payload` is set only for `:valid` via `QrPayload.build_for_scanner/1`
  (plain `ticket_code` text; no QR image library).
- Attendee and Event are loaded with safe `Repo.get/2` (no bang cache helpers).
- `FastCheck.Sales.TicketIssue.get_by_delivery_token_hash` supports indexed
  lookup on `delivery_token_hash`.
- Public route: `GET /t/:token` through `:browser` pipeline.
- Response headers on ticket page: `cache-control: no-store, private`,
  `pragma: no-cache`, `x-robots-tag: noindex, nofollow`.
- `/t/` requests are rate-limited per IP; raw token never appears in throttle
  keys, logs, or telemetry metadata.
- `Redactor.redact_url/1` filters `/t/<opaque-token>` paths and full URLs.

## Decisions Applied

- Read-only customer page; no state transitions or durable writes.
- Hash-only delivery token lookup; raw route token never stored or logged.
- Generic `:not_found` for malformed/unknown/invalid verify (no token existence leak).
- Text ticket code fallback instead of QR image dependency.
- Safe `Repo.get/2` for Attendee/Event instead of bang cache facades.
- Payment/scannability rules mirror existing scanner acceptance inline (no new
  public helper module).
- `authorize?: false` on internal Ash lookup inside `TicketPage` (matches
  several existing internal Sales read paths).
- No new migrations; reuses VS-08 `delivery_token_hash` index.
- `event_scoped_first`; `organization_id` deferred.

## Boundaries Still Enforced

- No `DeliveryAttempt` rows or WhatsApp/email/resend delivery behavior.
- No Paystack, checkout, inventory, or Redis mutation.
- No `FastCheck.Tickets.Issuer` changes.
- No Attendee, Order, PaymentAttempt, PaymentEvent, or TicketIssue mutation from
  the ticket page path.
- No scanner (`FastCheck.Attendees.Scan`) or mobile sync controller/DTO changes.
- No Android changes.
- No admin dashboard (VS-12).
- No token rotation/resend persistence.
- No QR image library.
- No Ash workflow actions on `TicketIssue`.

## Tests Added Or Updated

- `test/fastcheck/sales/ticket_page_test.exs` — valid/invalid/expired/revoked/
  not-ready/not-scannable states; missing attendee/event without crash; result
  excludes sensitive fields; hash-only persistence.
- `test/fastcheck_web/controllers/secure_ticket_controller_test.exs` — public
  access, headers, invalid HTML omits ticket code, rate-limit 429 smoke,
  sanitized blocked-path logging, no row mutation.
- `test/fastcheck/observability/redactor_test.exs` — `/t/` path and full URL
  redaction.
- `test/fastcheck/sales/domain_shell_test.exs` — `ticket_page.ex` in Sales file
  inventory.

## Verification Reported

From PR #385 test plan and CI:

```bash
mix test test/fastcheck/sales/ticket_page_test.exs
mix test test/fastcheck_web/controllers/secure_ticket_controller_test.exs
mix test test/fastcheck/observability/redactor_test.exs
mix test test/fastcheck/tickets/
mix test test/fastcheck/attendees/scan_test.exs
mix test test/fastcheck_web/controllers/mobile/sync_controller_test.exs
mix precommit
```

Results reported at merge:

- `mix precommit` — 808 tests, 0 failures, 4 skipped
- GitHub CI `Test (Elixir 1.17.3 OTP 26.2)` for PR #385 — pass

## Known Limitations

- Text ticket code display only; no QR image rendering.
- No delivery channel integration (WhatsApp/email/resend).
- No admin operator view of ticket page state or manual resend.
- Revocation/refund operator flows remain VS-15A work.
- Internal Ash lookup uses `authorize?: false`; a future hardening slice could
  switch to an explicit system actor if desired.
- No slice doc under `docs/fastcheck_sales/slices/`; feature pack at
  `docs/fastcheck_sales/feature_packs/0031_VS-11_secure-ticket-page/` is planning
  context only.

## Next Agent Guidance

**Reuse:**

- `FastCheck.Sales.TicketPage.resolve/1` for all customer ticket page
  classification; do not duplicate token lookup or validity rules elsewhere.
- VS-08 `TokenHash`, `DeliveryToken`, `QrPayload` for token/hash/payload work.
- `TicketIssue.get_by_delivery_token_hash` for hash lookup.
- Existing `GET /t/:token` route and `SecureTicketController` for customer display.
- Sanitized `/t/[FILTERED]` logging pattern in `RateLimiter` for any new
  token-bearing routes.

**Do not:**

- Store or log raw delivery tokens or token hashes in customer-facing output.
- Expose ticket code on invalid/expired/revoked/not-ready/not-scannable states.
- Mutate Attendee, Order, TicketIssue, payment, or delivery rows from the ticket
  page path.
- Recreate token hashing or add QR dependencies without an approved contract change.
- Bypass `TicketPage` from controllers, delivery workers, or WhatsApp paths.

**Keep green:**

- `test/fastcheck/sales/ticket_page_test.exs`
- `test/fastcheck_web/controllers/secure_ticket_controller_test.exs`
- `test/fastcheck/observability/redactor_test.exs`
- `test/fastcheck/tickets/`
- `test/fastcheck/attendees/scan_test.exs`
- `test/fastcheck_web/controllers/mobile/sync_controller_test.exs`
- `mix precommit`

## Next Slice

Recommended next slice: **VS-12 — Admin Sales Dashboard**

Entry condition:

- VS-11 is merged on `main`.
- `GET /t/:token` and `TicketPage.resolve/1` remain the customer ticket page
  contract.
- Issuance (`Issuer.issue_order/2`), payment, and mobile sync boundaries from
  VS-09/VS-10 remain unchanged.
- VS-12 should add operator/admin visibility without changing the secure ticket
  page read-only customer contract.
