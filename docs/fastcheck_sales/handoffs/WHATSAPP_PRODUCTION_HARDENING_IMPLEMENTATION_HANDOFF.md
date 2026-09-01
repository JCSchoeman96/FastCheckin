# FastCheck WhatsApp Production Hardening Implementation Handoff

Status: implementation handoff for `FC-WA-PROD-HARDENING v1.1.0`.

This handoff records the bounded WhatsApp-first paid-ticket hardening change. It
does not approve a sandbox rehearsal, production smoke, controlled pilot, or
public launch.

## Authority and baseline

- Authority: `docs/goal/FASTCHECK_WHATSAPP_PRODUCTION_HARDENING_GOAL_AUTHORITY_v1.1.0_REVIEWED.md`
  (`FC-WA-PROD-HARDENING v1.1.0`, reviewed).
- Repository: `/home/jcs/projects/FastCheckin`.
- Starting `main` SHA: `95482ac6964e073ef5d045d35f5bd11b2a275550`.
- Expected reviewed baseline: `main @ 95482ac6964e073ef5d045d35f5bd11b2a275550`.
- `origin/main` SHA observed before editing: `95482ac6964e073ef5d045d35f5bd11b2a275550`.
- Baseline drift: none in the scoped WhatsApp, webhook, DeliveryAttempt,
  checkout, Event, attendee-origin, runtime, CI, or VS-24E/runbook paths;
  `git diff` against the expected SHA was empty before implementation.
- `git fetch origin` was attempted during the airlock, but the execution
  environment rejected the network command under its approval policy. The
  existing `origin/main` ref was already the expected reviewed SHA and was
  recorded explicitly.
- Implementation worktree: `/home/jcs/projects/FastCheckin-whatsapp-hardening`.
- Implementation branch: `feature/whatsapp-production-hardening`.
- Final branch/head SHA: recorded in the exact-head PR evidence and final agent
  summary after the last publication commit.

## Beads disposition

The required hardening work was created and claimed by `JCSchoeman96`:

| Beads ID | Authority item | Disposition |
|---|---|---|
| `bd-j4m` | WH-H01 Meta DeliveryAttempt provider-status lifecycle | implementation complete; close after exact-head CI evidence |
| `bd-6tv` | WH-H01A status scope/correlation and untracked WAMIDs | implementation complete; close after exact-head CI evidence |
| `bd-7a8` | WH-H01B ambiguous ticket-link transport safety | implementation complete; close after exact-head CI evidence |
| `bd-yvs` | WH-H02 production dashboard authentication | implementation complete; close after exact-head CI evidence |
| `bd-okn` | WH-H03 Meta environment intent and webhook scope | implementation complete; close after exact-head CI evidence |
| `bd-fev` | WH-H04 event WhatsApp sales gate | implementation complete; close after exact-head CI evidence |
| `bd-3w0` | WH-H05 quantity parsing and dynamic prompts | implementation complete; close after exact-head CI evidence |
| `bd-x1b` | WH-H06 mixed Tickera/Sales attendee proof | implementation complete; close after exact-head CI evidence |
| `bd-ylt` | WH-H07 GitHub CI parity | implementation complete; close after exact-head CI evidence |
| `bd-3vb` | WH-H08 VS-24E/runbook alignment | implementation complete; close after exact-head CI evidence |

`bd dolt status` and `bd dolt start` are not supported by the installed Beads
client (`beads.role` is not configured); they returned the client help/status
diagnostic. `bd ready` initially had no open issues. The items above were
created, claimed, and kept aligned with the implementation until the remote
release gate is verified. Future/deferred GitHub issues were not closed.

## Implemented hardening

### WH-H02 and WH-H03: fail-closed runtime and dashboard configuration

- Added pure `FastCheck.RuntimeConfiguration` validation for strict booleans,
  production dashboard credentials, and production WhatsApp sandbox-mode intent.
- Production dashboard username/password must be present and non-blank; the
  known `fastcheck` fallback is rejected and the trimmed password must be at
  least 16 bytes. Development/test defaults remain usable.
- Production WhatsApp enablement requires an explicit recognized
  `META_WHATSAPP_SANDBOX_MODE`, WABA ID, phone-number ID, graph version, access
  token, app secret, and verify token.
- `FastCheck.Messaging.WhatsApp.Config.redacted_summary/0` exposes only safe
  configuration identity and environment intent; credentials are filtered.
- Signed webhook payloads are separately filtered to the configured WABA
  (`entry.id`) and phone (`value.metadata.phone_number_id`). Validly signed
  out-of-scope events are acknowledged and ignored without domain writes.

### WH-H01/H01A: provider evidence and DeliveryAttempt lifecycle

DeliveryAttempt-backed payment-link, ticket-link, and verified resend sends now
use the lifecycle:

```text
queued -> provider_accepted -> sent -> delivered -> read
queued/provider_accepted/sent -> failed|fallback_required
queued/provider_accepted/sent/failed -> manual_review
queued/provider_accepted/sent -> cancelled
```

Meta HTTP 2xx plus WAMID records `provider_accepted`; it never records `sent`,
`delivered`, or `read`. A dedicated provider-status normalizer accepts only the
bounded Meta status vocabulary and safe timestamps/error codes. The reconciler:

- verifies the already-signed, WABA/phone-scoped ingress before processing;
- correlates only `provider=meta`, `channel=whatsapp`, exact WAMID matches;
- writes immutable status evidence and applies monotonic provider-timestamp
  ordering;
- treats duplicate, old, deleted, unknown, and untracked conversational WAMIDs
  safely;
- routes contradictory later success after failure to deterministic
  `manual_review` without an automatic resend;
- detects multiple matching attempts and returns an ambiguity error rather than
  silently updating multiple rows; and
- never calls payment, ticket, inventory, scanner, or attendee authority code.

Ordinary menu/help/conversation replies remain outside DeliveryAttempt tracking.
Their expected status callbacks are bounded and redacted telemetry only.

### WH-H01B: ambiguous ticket-link transport

Ticket-link and verified-resend workers retain the existing pre-send secure-token
rotation but distinguish definitive provider responses from ambiguous transport
failures. A timeout/connection-loss outcome after dispatch marks the attempt
`manual_review`, retains the dedupe claim, returns a discard result, and does not
retry or rotate another token. A definitively rejected retryable HTTP response
uses the existing bounded retry path. Oban arguments, logs, audit metadata, and
telemetry never contain raw ticket URLs, tokens, or hashes. Failure to persist a
known provider acceptance is also fail-safe manual review with no unsafe retry.

### WH-H04: event-level WhatsApp sales gate

Added additive `events.whatsapp_sales_enabled BOOLEAN NOT NULL DEFAULT FALSE`.
The existing dashboard create/edit surfaces provide the deliberate toggle.
WhatsApp discovery requires a non-archived event, the gate, and an active
sellable WhatsApp offer. The authoritative `Checkout.start_checkout/3` boundary
rechecks the gate for effective channel `whatsapp`; stale confirmation after
disable returns a customer-safe unavailable response without creating an order
or hold. Idempotent replay and admin/internal paths preserve existing truth and
are not disabled by this WhatsApp-only gate.

### WH-H05: quantity authority

`TicketOffer.max_per_order` remains the sole business quantity ceiling. The
number normalizer accepts positive multi-digit tokens up to the defensive
9-digit input limit, retains `0` as Back, rejects signed/decimal/leading-zero
numeric forms, and leaves menu-state option bounds to the state machine. The
selected offer maximum is rendered dynamically in English and Afrikaans. Final
server-side checkout validation remains independent of the conversation prompt.
No Event-wide second quantity authority was added; issue #419 is explicitly
deferred as a separate product/architecture decision.

### WH-H06: mixed attendee-source proof

Added an integration regression covering one event with a Tickera attendee and a
`fastcheck_sales` attendee. It exercises Tickera reconciliation, mobile sync,
valid Sales scanning, Sales revocation/invalidation, and post-revocation Tickera
scanning. Assertions require distinct attendee IDs, preserved source/ticket
identity, both eligible rows visible before revocation, and only the Sales row
becoming not scannable. No source collision was exposed by the test design; the
test remains dependent on the repository Postgres/Redis services in CI.

### WH-H07 and WH-H08

GitHub CI now explicitly runs warnings-as-errors compilation, format checking,
Credo strict, Dialyzer, Sobelow, Postgres/Redis setup, migrations, and the full
test suite. Existing VS-24E runbooks, evidence/checklists, failure matrix,
delivery state machine, monitoring, and incident material now distinguish
provider acceptance from Meta status evidence and cover scope, redaction, event
disable/stale checkout, multi-digit quantity, mixed sources, and ambiguous
ticket-link transport. External Meta and Paystack checks remain explicitly
manual; mocks are not claimed as real provider success.

## Exact migrations

1. `priv/repo/migrations/20260901090000_add_whatsapp_sales_hardening_fields.exs`
   adds the additive, non-null, default-false `events.whatsapp_sales_enabled`
   field.
2. `priv/repo/migrations/20260901091000_harden_whatsapp_delivery_attempt_lifecycle.exs`
   adds provider acceptance/status/read/failure evidence fields; replaces the
   status constraint with the explicit lifecycle; deterministically backfills
   legacy Meta/WhatsApp `sent` rows to `provider_accepted`/`accepted`; aborts
   before uniqueness if historical non-null WAMIDs collide; adds the scoped
   partial WAMID uniqueness index and immutable status-evidence table/indexes;
   and provides a non-destructive rollback mapping `provider_accepted -> sent`
   and `read -> delivered` before restoring the legacy constraint.

## Security and protected values

Preserved raw-body Meta signature verification, Paystack signature verification,
payment verification, ticket issuance idempotency, scanner/admission authority,
inventory authority, attendee-source authority, and authenticated dashboard
routes. New status telemetry uses hashes/bounded classifications only. No new
logging/evidence path records raw phone, email, `wa_id`, recipient ID, customer
text, raw provider payload, Meta/Paystack secret, access code, payment URL,
secure ticket URL, delivery token/hash, QR secret, OTP, or protected raw struct.
Sobelow passed and a manual diff review found no new protected-value leakage.

The Codex Security diff workbench was started for the working-tree diff
(`scanId 3bfabdc8-52f7-4b20-9e03-7044e3d72fac`) and the architecture threat-model
review was completed. The security workbench artifact root later became
unavailable (`Codex Security scan artifact root is not a safe regular
directory`), so no canonical Codex Security report was claimed. TAC status also
reported that the security connector was not connected. Manual source/diff
review plus Sobelow are the available repository security evidence; the exact
workbench limitation is residual tooling risk, not a finding.

## Focused verification

Passed locally on the implementation worktree:

- Pure hardening suite covering runtime config, provider status, webhook scope,
  input normalization, dynamic menu rendering, client redaction/config,
  provider boundary, resource skeletons, and migration compatibility:
  `68 tests, 0 failures`.
- `env MIX_ENV=test mix format --check-formatted`.
- `env MIX_ENV=test mix compile --warnings-as-errors`.
- `env MIX_ENV=test mix credo --strict` (`11663 mods/funs, found no issues` on
  the final static run).
- `env MIX_ENV=test mix sobelow --exit --compact`.
- `git diff --check`.

Database-backed focused tests compile but cannot execute in this environment:
the repository expects PostgreSQL at `localhost:5434` and Redis at `localhost:6380`,
and neither service is available. A changed-test run reached `215 tests` with
`147` setup failures caused by the unavailable `FastCheck.Repo`; no assertion
failure was observed before setup failed. The mixed-source and webhook lifecycle
integration proof therefore requires the pinned CI services.

`mix precommit` was run against the final worktree. Dependency resolution,
warnings-as-errors compilation, formatting, and Credo passed; it stopped at
`mix ecto.create` because PostgreSQL `localhost:5434` refused the connection
(`The database for FastCheck.Repo couldn't be created: killed`).

`mix ci` was run against the final worktree. It stopped at the repository's
Dialyzer step with 54 existing host-toolchain warnings/errors under Elixir
1.19.3/OTP 28; the host does not provide the workflow's pinned Elixir 1.17.3 /
OTP 26.2. The reported failures are in pre-existing code paths; the new
provider-status/reconciler modules do not appear in the Dialyzer error list.
Because the alias halts there, local CI did not reach Sobelow/database tests.
The required remote exact-head CI is the release evidence for the pinned
toolchain and services.

The reviewed baseline's prior GitHub CI run was successful:
run `31695635483` on the expected SHA. That historical workflow did not yet
include this goal's Dialyzer parity step; the final PR exact-head run must be
checked separately.

## Exact changed-file inventory

### Runtime, domain, provider, worker, and web code

- `.github/workflows/ci.yml`
- `config/config.exs`
- `config/runtime.exs`
- `lib/fastcheck/runtime_configuration.ex`
- `lib/fastcheck/events.ex`
- `lib/fastcheck/events/event.ex`
- `lib/fastcheck/messaging/whatsapp/client.ex`
- `lib/fastcheck/messaging/whatsapp/config.ex`
- `lib/fastcheck/messaging/whatsapp/conversation_state_machine.ex`
- `lib/fastcheck/messaging/whatsapp/copy.ex`
- `lib/fastcheck/messaging/whatsapp/delivery_status_reconciler.ex`
- `lib/fastcheck/messaging/whatsapp/input_normalizer.ex`
- `lib/fastcheck/messaging/whatsapp/menu_renderer.ex`
- `lib/fastcheck/messaging/whatsapp/provider_status.ex`
- `lib/fastcheck/messaging/whatsapp/response.ex`
- `lib/fastcheck/messaging/whatsapp/webhook_scope.ex`
- `lib/fastcheck/sales/admin_refunds.ex`
- `lib/fastcheck/sales/audit_views.ex`
- `lib/fastcheck/sales/checkout.ex`
- `lib/fastcheck/sales/delivery_attempt.ex`
- `lib/fastcheck/sales/sandbox_fixtures.ex`
- `lib/fastcheck/workers/send_whatsapp_payment_link_worker.ex`
- `lib/fastcheck/workers/send_whatsapp_ticket_link_worker.ex`
- `lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex`
- `lib/fastcheck_web/live/dashboard_live.ex`
- `lib/fastcheck_web/live/sales/order_show_live.ex`

### Tests and test support

- `test/fastcheck/runtime_configuration_test.exs`
- `test/fastcheck/messaging/whatsapp/boundary_test.exs`
- `test/fastcheck/messaging/whatsapp/client_test.exs`
- `test/fastcheck/messaging/whatsapp/config_test.exs`
- `test/fastcheck/messaging/whatsapp/conversation_state_machine_test.exs`
- `test/fastcheck/messaging/whatsapp/delivery_status_reconciler_test.exs`
- `test/fastcheck/messaging/whatsapp/e2e/whatsapp_paid_core_test.exs`
- `test/fastcheck/messaging/whatsapp/event_sales_gate_test.exs`
- `test/fastcheck/messaging/whatsapp/input_normalizer_test.exs`
- `test/fastcheck/messaging/whatsapp/log_redaction_test.exs`
- `test/fastcheck/messaging/whatsapp/menu_renderer_test.exs`
- `test/fastcheck/messaging/whatsapp/payment_flow_test.exs`
- `test/fastcheck/messaging/whatsapp/provider_status_test.exs`
- `test/fastcheck/messaging/whatsapp/resend_ticket_e2e_test.exs`
- `test/fastcheck/messaging/whatsapp/webhook_scope_test.exs`
- `test/fastcheck/sales/checkout_expiry_test.exs`
- `test/fastcheck/sales/conversation_resource_migrations_test.exs`
- `test/fastcheck/sales/delivery_attempt_migration_compatibility_test.exs`
- `test/fastcheck/sales/e2e/revocation_scanner_visibility_test.exs`
- `test/fastcheck/sales/sandbox_fixtures_test.exs`
- `test/fastcheck/sales/ticket_and_delivery_resource_migrations_test.exs`
- `test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs`
- `test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs`
- `test/fastcheck/workers/send_whatsapp_payment_link_worker_test.exs`
- `test/fastcheck/workers/send_whatsapp_ticket_link_worker_test.exs`
- `test/fastcheck/workers/whatsapp_inbound_worker_test.exs`
- `test/fastcheck_web/browser_auth_test.exs`
- `test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs`
- `test/support/sales_checkout_fixtures.ex`
- `test/support/sales_e2e_fixtures.ex`
- `test/support/whatsapp_webhook_test_support.ex`

### Runbooks and evidence material

- `docs/fastcheck_sales/feature_packs/0041_VS-20_whatsapp-delivery-window-handling/VS-20-FEATURE_PACK.md`
- `docs/fastcheck_sales/feature_packs/0049_VS-24E_production-checkout-ticket-delivery-smoke-test/ACCEPTANCE_CHECKLIST.md`
- `docs/fastcheck_sales/feature_packs/0049_VS-24E_production-checkout-ticket-delivery-smoke-test/EVIDENCE_TEMPLATE.md`
- `docs/fastcheck_sales/feature_packs/0049_VS-24E_production-checkout-ticket-delivery-smoke-test/TOON_PROMPTS.md`
- `docs/fastcheck_sales/runbooks/INCIDENT_RESPONSE.md`
- `docs/fastcheck_sales/runbooks/POST_LAUNCH_MONITORING.md`
- `docs/fastcheck_sales/runbooks/SANDBOX_DRESS_REHEARSAL.md`
- `docs/fastcheck_sales/runbooks/VS-23C_FINAL_WHATSAPP_LAUNCH_RUNBOOK.md`
- `docs/fastcheck_sales/runbooks/VS-24E_FAILURE_MATRIX.md`
- `docs/fastcheck_sales/runbooks/VS-24E_PRODUCTION_CHECKOUT_TICKET_DELIVERY_SMOKE_TEST.md`
- `docs/fastcheck_sales/runbooks/VS-24E_PRODUCTION_LOW_VALUE_SMOKE.md`
- `docs/fastcheck_sales/state_machines/DELIVERY_ATTEMPT_STATE_MACHINE.md`

### Migrations

- `priv/repo/migrations/20260901090000_add_whatsapp_sales_hardening_fields.exs`
- `priv/repo/migrations/20260901091000_harden_whatsapp_delivery_attempt_lifecycle.exs`

## Residual risks and manual VS-24E actions

- Run the full pinned Elixir/OTP/Postgres/Redis CI and inspect every check on
  the exact final PR head.
- Manually verify the Meta business portfolio, WABA, registered phone,
  token type/permissions, templates, webhook subscription, and phone
  two-step verification. `sandbox_mode` is intent/configuration, not provider
  isolation proof.
- Run the separately authorized VS-24E real sandbox dress rehearsal, including
  provider acceptance versus real Meta status callbacks, failed-status operator
  visibility, out-of-scope callback acknowledgement, stale event disable,
  multi-digit quantity, secure ticket behavior, and redaction review.
- Paystack external sandbox verification and any later low-value production
  smoke remain manual and were not run here.
- Ambiguous ticket-link attempts have no new automatic retry. Operator/manual
  review must resolve whether a first message was delivered before any separately
  authorized resend action.
- The existing trusted internal DeliveryAttempt compatibility actions
  (`mark_sent`, `mark_delivered`, `mark_read`) remain available for non-webhook
  system callers; the hardened Meta callback path uses only the reconciler.
- No dedicated new manual-resolution service action was introduced; existing
  manual-review operations are the bounded operator path.
- The Codex Security artifact/TAC workbench limitation described above remains
  a tooling residual; no finding was inferred from it.

## Deferred issue disposition and scope firewall

- #419 remains deferred as a separate event-wide quantity-authority decision;
  this implementation deliberately uses only `TicketOffer.max_per_order`.
- #418/#420 are covered by the generalized numeric parser, state-specific menu
  bounds, dynamic copy, and checkout authority tests.
- #434, #435, #436, and #437 remain future operator/admin-scope work and were
  not closed or implemented here. The later wallet work, public web checkout,
  customer PDF attachment delivery, reminders, CRM/PII reorder, scanner or
  Android redesign, payment/inventory/ticket authority redesign, Tickera
  rewrite, unrelated dependency upgrades, and broad design-system changes are
  explicitly outside this PR.
- No prohibited wallet, public-web, customer-PDF-delivery, or unrelated product
  scope leaked into the implementation diff. No Android files were changed.

## PR and release status

PR URL, final branch/head SHA, and exact-head CI run ID are filled in after the
branch is pushed and the open PR completes its pinned workflow. The PR is not
to be merged as part of this goal.

`PR OPENED; NOT MERGED.`

Final release status is only valid after exact-head GitHub CI evidence is
recorded here:

```text
CODE HARDENING: PENDING EXACT-HEAD CI
AUTOMATED RELEASE GATES: PENDING EXACT-HEAD CI
SANDBOX DRESS REHEARSAL: NOT YET IMPLIED
PRODUCTION: NOT YET IMPLIED
```
