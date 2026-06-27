# VS-22 Implementation Handoff

## Status

Merged.

PR: #410 — [codex] test(sales): add VS-22 e2e sandbox coverage  
Merge commit: `308ce745dec6d5c480f11262f2de4f8a1bfc1e6c`  
Merged at: 2026-06-27T14:36:47Z  
Branch: `vs-22-end-to-end-sandbox-tests`

## What Changed

VS-22 added end-to-end sandbox test coverage for the selected FastCheck Sales
launch scope. The slice proves full-path and critical failure behavior across
WhatsApp-first paid core, admin-assisted sales, and internal pilot entry points.

Coverage includes checkout-to-scanner acceptance, duplicate Paystack webhook and
Oban worker idempotency, payment mismatch and manual-review paths, checkout
expiry and late-payment recovery, admin revocation with scanner/mobile denial,
and WhatsApp payment/ticket delivery (including outside-24h template sends).

One new test support module composes existing checkout, Paystack, WhatsApp, Oban,
Redis cleanup, mobile sync, and scanner test boundaries. No production code,
migrations, router changes, dependency changes, or public web checkout E2E were
added.

## Files Changed

- `test/support/sales_e2e_fixtures.ex` — shared E2E helpers for event/offer
  setup, initialized checkout, Paystack webhook ingest, mobile scan ingestion,
  inventory/session manipulation, and Sales entity reload/assert helpers.
- `test/fastcheck/sales/e2e/checkout_to_scanner_test.exs` — paid WhatsApp
  checkout through secure ticket page, mobile attendee sync, and scanner check-in;
  duplicate webhook/worker idempotency.
- `test/fastcheck/sales/e2e/payment_failure_paths_test.exs` — amount/currency/
  reference mismatch manual review, provider failed/pending non-issuance, and
  unmatched webhook handling.
- `test/fastcheck/sales/e2e/checkout_expiry_recovery_test.exs` — hold release on
  expiry, late-payment manual review, and verification-before-expiry race safety.
- `test/fastcheck/sales/e2e/revocation_scanner_visibility_test.exs` — admin
  revocation invalidates secure ticket page and mobile scan; reason required.
- `test/fastcheck/sales/e2e/admin_assisted_sales_test.exs` — admin-assisted and
  internal-pilot checkout through shared Sales core; confirms web checkout absent.
- `test/fastcheck/messaging/whatsapp/e2e/whatsapp_paid_core_test.exs` — WhatsApp
  paid-core conversation flow, payment/ticket link workers, outside-window
  template delivery with dedupe, and log redaction.

## Contracts Now Available

- `@moduletag :e2e` test suite (15 tests) guards the selected launch scope end to
  end; run with `mix test --only e2e`.
- `FastCheck.SalesE2EFixtures` is the authoritative E2E composition layer for
  Sales sandbox tests; reuse it instead of duplicating checkout/Paystack/mobile
  setup.
- Full-path proof exists for: WhatsApp checkout → Paystack verify → ticket issue
  → secure ticket page → mobile sync → scanner acceptance.
- Idempotency proof exists for duplicate Paystack webhooks and duplicate
  `PaystackWebhookWorker`, `VerifyPaymentWorker`, and `IssueTicketsWorker` runs.
- Failure-path proof exists for payment mismatch, provider failed/pending,
  unmatched webhooks, checkout expiry, late payment, and admin revocation.
- Launch-scope channel proof exists: `source_channel = "whatsapp"`, `"admin"`,
  and `"internal_pilot"`; public web checkout remains untested because it is out
  of first launch scope.
- Log redaction assertions guard buyer email, phone, Paystack URLs, and delivery
  token hashes in E2E capture paths.

## Decisions Applied

- `selected_launch_scope_from_VS-00D` — WhatsApp-first paid core, admin-assisted
  sales, and internal pilot are in scope; web checkout is deferred.
- `test_only_slice` — no production behavior, migrations, or router changes.
- `compose_existing_boundaries` — reuses `SalesCheckoutFixtures`,
  `PaystackSupport`, `WebhookTestSupport`, `InMemoryStore`, and existing workers.
- `oban_manual_perform` — workers are exercised via `Oban.Testing` `perform_job/2`,
  not background scheduling alone.
- `no_wall_clock_sleeps` — expiry and delivery-window scenarios set timestamps
  directly (`set_session_expires_at!/2`, `last_message_at` offset).
- `event_scoped_first` — actors, mobile tokens, and inventory keys stay
  event-scoped through existing fixtures.
- `log_redaction_in_e2e` — sensitive values must not appear in captured logs.

## Boundaries Still Enforced

- No new production business behavior, Paystack verification rules, ticket
  issuance logic, scanner logic, or WhatsApp menu behavior.
- No public web checkout E2E (web checkout remains out of first launch scope).
- No runbook finalization (VS-23B / VS-23C).
- No new provider HTTP clients or real Paystack/Meta calls in tests.
- No migrations, router changes, Redis script changes, or Android/mobile API
  contract changes.
- No admin UI feature implementation beyond what prior slices already shipped.

## Tests Added Or Updated

All files are new; no existing tests were modified.

| File | Tests | What it verifies |
|------|-------|------------------|
| `checkout_to_scanner_test.exs` | 2 | Happy path to scanner; duplicate webhook/worker idempotency |
| `payment_failure_paths_test.exs` | 4 | Mismatch manual review; currency/reference failures; failed/pending provider; unmatched webhook |
| `checkout_expiry_recovery_test.exs` | 3 | Expiry hold release; late payment manual review; verify-before-expiry race |
| `revocation_scanner_visibility_test.exs` | 2 | Revocation removes ticket validity and scan acceptance; reason required |
| `admin_assisted_sales_test.exs` | 2 | Admin-assisted issuance path; internal pilot without web checkout |
| `whatsapp_paid_core_test.exs` | 2 | WhatsApp paid core flow; outside-24h template send with dedupe |

**Total:** 15 E2E tests (`@moduletag :e2e`).

## Verification Reported

From PR #410:

```bash
mix test --only e2e
# 15 tests, 0 failures

# targeted regression suite
# 334 tests, 0 failures

mix precommit
# 1042 tests, 0 failures, 4 skipped
```

## Known Limitations

- Web checkout E2E is intentionally absent; deferred until a future web
  checkout slice is in launch scope.
- E2E tests use test doubles (`:paystack_request_fun`, `:whatsapp_request_fun`,
  in-memory mobile scan store) — not live provider or device integration.
- Delivery token setup for secure-ticket-page assertions uses direct DB updates in
  tests; this is test scaffolding, not a new production contract.
- VS-23B core launch runbooks and VS-23C WhatsApp runbooks are not finalized.
- Ops dashboard validation via VS-21B views is available but not exercised in
  these E2E tests.

## Next Agent Guidance

**Reuse:**

- `FastCheck.SalesE2EFixtures` for any new Sales E2E or launch-validation tests.
- Existing Paystack (`PaystackSupport`), WhatsApp (`WebhookTestSupport`), and
  checkout fixtures; do not duplicate setup.
- `@moduletag :e2e` tagging convention for full-path sandbox tests.
- `mix test --only e2e` as the targeted gate for launch-scope regression.

**Do not:**

- Add production code under the guise of “making E2E easier” — extend test support
  only unless a separate slice explicitly scopes runtime changes.
- Bypass idempotency, manual-review, expiry, or revocation boundaries to shorten
  tests.
- Add public web checkout E2E without updating launch scope (VS-00D).
- Remove or weaken log-redaction assertions in E2E capture paths.
- Recreate parallel E2E fixture modules; extend `SalesE2EFixtures` instead.

**Authoritative for launch-scope proof:** the six E2E test modules above plus
`test/support/sales_e2e_fixtures.ex`.

**Tests that must remain green:** all 15 `:e2e` tests; full `mix precommit`
(1042+ tests). Any change to checkout, payment verification, ticket issuance,
scanner visibility, revocation, WhatsApp delivery, or expiry logic should re-run
`mix test --only e2e` and targeted Sales regression suites.

## Next Slice

Recommended next slice:
**VS-23B — Final Core Launch Runbooks**

Entry condition:

- VS-22 E2E sandbox tests are merged and green (`mix test --only e2e`).
- Selected launch scope is documented (VS-00D / `LAUNCH_SCOPE_TEST_REQUIREMENTS.md`).
- VS-12 admin dashboard, VS-15A revocation/scanner visibility, and VS-21B ops/
  audit views are available for runbook cross-reference.
- If WhatsApp is in launch scope, also plan **VS-23C — Final WhatsApp Launch
  Runbooks** after VS-23B or in parallel once VS-20 delivery-window behavior is
  understood from VS-22 WhatsApp E2E proof.
