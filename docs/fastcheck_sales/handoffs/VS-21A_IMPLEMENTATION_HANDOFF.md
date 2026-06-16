# VS-21A Implementation Handoff

## Status

Merged.

PR: #357 — feat(sales): VS-21A observability and log redaction foundation  
Merge commit: `b7c0b9b8501aca6c252c58a1446326ac3286cb02`  
Merged at: 2026-06-16T19:17:20Z  
Branch: `cursor/vs-21a-observability-redaction-foundation`

## What Changed

VS-21A added a shared Sales observability foundation: pure redaction helpers,
a catalog of 23 approved Sales `:telemetry` event names, correlation/idempotency
propagation helpers, hardened Sentry filtering, and Logger metadata allowlist
extensions. `StateTransitionSupport` now delegates transition **metadata**
sanitization to the shared redactor.

No dashboards, DB tables, migrations, provider HTTP, business workflows, or
scanner/mobile behavior were added.

## Files Changed

- `lib/fastcheck/observability.ex` — facade; defdelegates to Redactor,
  TelemetryNames, and Correlation; links security policy docs.
- `lib/fastcheck/observability/redactor.ex` — recursive PII/token/payload
  redaction; `safe_metadata/1`; fail-closed `redact_url/1` for payment/ticket/
  delivery/provider URLs.
- `lib/fastcheck/observability/telemetry_names.ex` — 23 approved Sales telemetry
  event lists (`TelemetryNames.all/0` and grouped accessors).
- `lib/fastcheck/observability/correlation.ex` — `ensure_correlation_id/1`,
  `operational_metadata/1`, `for_oban_args/1`, `merge_metadata/2`.
- `lib/fastcheck_web/sentry_filter.ex` — recursive filtering of request data,
  headers, query string/query map, URL, and extra via `Redactor`.
- `lib/fastcheck/sales/state_transition_support.ex` — metadata sanitization
  delegates to `Redactor.safe_metadata/1`; top-level `idempotency_key` field
  on `StateTransition` unchanged.
- `config/config.exs` — appended approved Sales Logger metadata keys (existing
  scanner keys preserved).
- `test/fastcheck/observability/redactor_test.exs` — redaction, recursion,
  `safe_metadata`, URL fail-closed behavior.
- `test/fastcheck/observability/telemetry_names_test.exs` — 23-event catalog.
- `test/fastcheck/observability/correlation_test.exs` — correlation preservation
  and bounded operational metadata.
- `test/fastcheck/observability/state_transition_support_redaction_test.exs` —
  metadata drops PII/tokens/idempotency_key; top-level idempotency_key persists.
- `test/fastcheck_web/sentry_filter_test.exs` — recursive Sentry filtering and
  safe-ID preservation.

## Contracts Now Available

- `FastCheck.Observability.Redactor` is the single shared redaction module for
  Sales logs, metadata maps, and Sentry-bound structures.
- `Redactor.safe_metadata/1` drops forbidden keys **including `idempotency_key`**
  from arbitrary metadata maps. Bounded Logger metadata may still include
  `:idempotency_key` via `Correlation.operational_metadata/1` or explicit
  `Logger.metadata/1`.
- `FastCheck.Observability.TelemetryNames.all/0` returns exactly **23** approved
  `[:fastcheck, :sales, ...]` event names for future slices to emit.
- `FastCheck.Observability.Correlation` helpers preserve existing
  `correlation_id`, fall back to `request_id`, and never derive IDs from buyer
  phone/email.
- `FastCheckWeb.SentryFilter` recursively redacts Sales-sensitive request/extra
  data and preserves safe operational IDs (`order_id`, `payment_attempt_id`,
  `ticket_issue_id`, etc.).
- `Redactor.redact_url/1` fails closed (`[FILTERED]`) on Paystack/payment/ticket/
  delivery/provider/token-bearing URLs; safe non-sensitive URLs may return base
  path with query removed.
- Policy alignment docs remain authoritative:
  `docs/fastcheck_sales/security/LOG_REDACTION_POLICY.md` and
  `SECURITY_PII_TOKEN_MASTER.md`.

## Decisions Applied

- Extend existing `FastCheckWeb.SentryFilter` and Logger metadata config; no
  parallel logging stack.
- Pure helper modules only; no DB writes, Redis, Oban workers, or PubSub in this
  slice.
- `idempotency_key` stripped from transition metadata and arbitrary metadata
  maps; top-level `StateTransition.idempotency_key` column behavior unchanged.
- Existing inventory telemetry names in reconciler/recovery/health were **not**
  renamed to the VS-21A catalog.
- Scanner/check-in Logger metadata keys in `config/config.exs` were preserved.

## Boundaries Still Enforced

- No operational dashboards or audit LiveViews (VS-21B).
- No materialized views, Prometheus exporter changes, or alert routing.
- No Paystack/Meta HTTP, webhooks, ticket issuance, delivery workers, or admin
  UI.
- No Ash resource/schema/migration changes.
- No router/endpoint/scanner/mobile changes.
- No refactors of checkout, inventory, reconciliation, recovery, or secondary
  entrypoints to emit new telemetry names (helpers only).

## Tests Added Or Updated

- `test/fastcheck/observability/redactor_test.exs` — PII/token/payload
  redaction, nested maps, `safe_metadata`, URL fail-closed vs safe strip.
- `test/fastcheck/observability/telemetry_names_test.exs` — 23 events, no
  user-input-built names.
- `test/fastcheck/observability/correlation_test.exs` — correlation/request_id
  rules, bounded Oban arg extraction.
- `test/fastcheck/observability/state_transition_support_redaction_test.exs` —
  metadata vs top-level idempotency_key boundary.
- `test/fastcheck_web/sentry_filter_test.exs` — recursive request/extra
  filtering, safe IDs, non-map tolerance.

Existing regression tests that must stay green:

- `test/fastcheck/sales/order_checkout_core_test.exs` (checkout log redaction)
- `test/fastcheck_web/sales/secondary_entrypoints_log_redaction_test.exs`

## Verification Reported

From PR #357 test plan and implementation verification:

```bash
mix test test/fastcheck/observability/
mix test test/fastcheck_web/sentry_filter_test.exs
mix test test/fastcheck/sales/order_checkout_core_test.exs
mix test test/fastcheck_web/sales/secondary_entrypoints_log_redaction_test.exs
mix precommit
```

Results reported at merge:

- `mix precommit` green (563 tests, 0 failures, 4 skipped) after URL
  fail-closed patch included in squash merge.

## Known Limitations

- Sales modules do not yet emit telemetry through `TelemetryNames`; catalog is
  declared but not wired into checkout/payment/WhatsApp flows.
- Existing inventory modules still use ad-hoc telemetry atoms (e.g.
  `:reconcile_started`, `:manual_review_required`) not in the 23-event catalog.
- No VS-21A slice doc under `docs/fastcheck_sales/slices/` was added in the
  merge; feature pack remains planning reference only.
- `FastCheck.Telemetry` platform handlers unchanged; Sales metrics dashboards
  deferred to VS-21B.

## Next Agent Guidance

**Reuse:**

- `FastCheck.Observability.Redactor` for any Sales logging, metadata, or error
  reporting that may touch PII, tokens, or provider payloads.
- `TelemetryNames.all/0` (or grouped accessors) when adding `:telemetry.execute`
  calls in future Sales slices — do not invent ad-hoc event strings.
- `Correlation.ensure_correlation_id/1` and `operational_metadata/1` at
  controller/worker boundaries.
- `FastCheckWeb.SentryFilter` — extend only if new sensitive field classes
  appear; do not add a second filter.

**Do not:**

- Recreate inline redaction in Paystack/WhatsApp/ticketing modules.
- Log raw provider payloads, authorization URLs, delivery/QR tokens, or buyer
  phone/email in Logger metadata or Sentry extra.
- Put `idempotency_key` inside `StateTransition` metadata maps.
- Rename existing inventory telemetry without an explicit migration slice.
- Bypass `safe_metadata/1` when persisting transition metadata.

**Authoritative tests:** observability tests above plus existing checkout log-
redaction tests.

## Next Slice

Recommended next slice: **VS-21B — Operational Metrics and Audit Views**

Entry condition:

- VS-21A merged (this handoff).
- Use `TelemetryNames` and `Redactor` when adding metrics/logging in VS-21B; do
  not rename the 23 approved events.
- Extend existing `FastCheckWeb.Telemetry` / metrics surfaces per VS-21B feature
  pack; no parallel metrics supervisor.
