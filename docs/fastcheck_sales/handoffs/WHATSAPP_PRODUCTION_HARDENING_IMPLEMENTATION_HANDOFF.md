# FastCheck WhatsApp Production Hardening Implementation Handoff

Status: implementation handoff for FC-WA-PROD-HARDENING v1.1.0.

This handoff records the bounded WhatsApp-first paid-ticket hardening change. It
does not approve a sandbox rehearsal, production smoke, controlled pilot, or
public launch.

## Authority, baseline, and publication

- Authority used: /home/jcs/projects/FastCheckin/docs/goal/FASTCHECK_WHATSAPP_PRODUCTION_HARDENING_GOAL_AUTHORITY_v1.1.0_REVIEWED.md, FC-WA-PROD-HARDENING v1.1.0 (reviewed).
- Repository: /home/jcs/projects/FastCheckin.
- Starting main SHA: 95482ac6964e073ef5d045d35f5bd11b2a275550.
- Expected reviewed baseline: main @ 95482ac6964e073ef5d045d35f5bd11b2a275550.
- origin/main observed before editing: 95482ac6964e073ef5d045d35f5bd11b2a275550.
- Baseline drift assessment: no drift in WhatsApp messaging, webhook ingress,
  DeliveryAttempt, Sales checkout, Event, attendee-origin, runtime, CI, or
  VS-24E/runbook paths. The scoped diff from the expected SHA was empty before
  implementation.
- git fetch origin was attempted during the airlock; this execution
  environment rejected the network command under its approval policy. The
  existing origin/main ref was already the expected SHA and was recorded.
- Dedicated worktree: /home/jcs/projects/FastCheckin-whatsapp-hardening.
- Branch: feature/whatsapp-production-hardening.
- Final implementation code head: 9f113815ff1a2176c99e18cfa592fb4a3cb47a3e.
  The branch is 15 commits ahead of and 0 commits behind the reviewed base;
  final handoff publication is documentation-only.
- PR: #462 (https://github.com/JCSchoeman96/FastCheckin/pull/462), base main,
  open and not merged.

## Beads disposition

bd dolt status and bd dolt start were run during airlock. The installed client
reported that beads.role is not configured and printed its diagnostic; bd ready
had no prior ready work. The required work was created and claimed. No
future/deferred GitHub issue was closed.

| Beads ID | Authority item | Disposition |
|---|---|---|
| bd-j4m | WH-H01 DeliveryAttempt provider-status lifecycle | completed after exact-head release gates passed |
| bd-6tv | WH-H01A callback scope/correlation | completed after exact-head release gates passed |
| bd-7a8 | WH-H01B ambiguous ticket-link transport | completed after exact-head release gates passed |
| bd-yvs | WH-H02 dashboard authentication | completed after focused and exact-head evidence |
| bd-okn | WH-H03 Meta environment and webhook scope | completed after focused and exact-head evidence |
| bd-fev | WH-H04 event WhatsApp sales gate | completed after database-backed exact-head tests |
| bd-3w0 | WH-H05 quantity correction | completed after focused and exact-head evidence |
| bd-x1b | WH-H06 mixed attendee-source proof | completed after database-backed exact-head tests |
| bd-ylt | WH-H07 CI/release-gate parity | completed after exact-head workflow passed every required gate |
| bd-3vb | WH-H08 VS-24E/runbook alignment | completed after required runbook/evidence updates |
| bd-v8v | P1 blocker: pre-existing Dialyzer release debt | resolved by minimal warning fixes; no gate was weakened |
| bd-4hi | P1 HIGH Hex advisory triage | completed on separate stacked PR #463; not merged here |

## Implemented hardening

### WH-H02 and WH-H03: fail-closed runtime and dashboard configuration

- Added pure FastCheck.RuntimeConfiguration validation for strict booleans,
  production dashboard credentials, and production WhatsApp sandbox-mode intent.
- Production dashboard username/password must be explicit, trimmed, and
  non-blank; the known fastcheck fallback is rejected and the password must be
  at least 16 bytes. Development/test defaults remain usable.
- Production WhatsApp enablement requires explicit recognized
  META_WHATSAPP_SANDBOX_MODE, WABA ID, phone-number ID, graph version, access
  token, app secret, and verify token.
- FastCheck.Messaging.WhatsApp.Config.redacted_summary/0 exposes only safe
  configuration identity and environment intent; protected values are filtered.
- Raw-body Meta signature verification remains mandatory. Signed payloads are
  separately filtered to the configured WABA (entry.id) and phone
  (value.metadata.phone_number_id). Validly signed out-of-scope events are
  acknowledged and ignored without Sales-domain writes.

### WH-H01/H01A: provider evidence and DeliveryAttempt lifecycle

Payment-link, ticket-link, and verified resend DeliveryAttempts use the explicit
lifecycle:

~~~text
queued -> provider_accepted -> sent -> delivered -> read
queued/provider_accepted/sent -> failed|fallback_required
queued/provider_accepted/sent/failed -> manual_review
queued/provider_accepted/sent -> cancelled
~~~

Meta HTTP 2xx plus WAMID records provider_accepted; it never records sent,
delivered, or read. The dedicated provider-status normalizer and reconciler:

- accepts only the bounded Meta status vocabulary and safe timestamps/error
  classifications;
- verifies signed ingress before processing and enforces exact WABA/phone
  scope;
- correlates only exact provider=meta, channel=whatsapp, WAMID matches;
- writes immutable status evidence and applies provider-timestamp ordering;
- is idempotent for duplicate callbacks, rejects/regulates stale evidence, and
  routes contradictory stronger evidence to manual review;
- ignores expected WAMIDs from untracked ordinary replies with bounded,
  redacted telemetry;
- ignores unknown WAMIDs without creating phantom attempts;
- detects multiple historical matches and returns an ambiguity error rather than
  silently updating more than one DeliveryAttempt; and
- never calls payment, ticket, inventory, scanner, attendee, or admission
  authority code.

Ordinary menu/help/conversation replies remain outside DeliveryAttempt tracking.
Meta status callbacks are not parsed as conversation commands.

### WH-H01B: ambiguous ticket-link transport

Ticket-link and verified-resend workers retain the existing pre-send secure-token
rotation but distinguish definitive provider rejection from ambiguous transport
outcomes. A timeout/connection-loss result after dispatch marks the attempt
manual_review, retains the dedupe claim, returns a discard result, and does
not retry or rotate a second token. A successful response without a WAMID, a
malformed success response, and a 5xx response are also treated as ambiguous;
the worker does not auto-retry them. Definitive 429 rejection remains on the
bounded retry path. Async failed callbacks are evidence only. Raw ticket URLs,
tokens, hashes, and protected values are absent from Oban arguments, logs,
audit metadata, and telemetry.

### WH-H04: event-level WhatsApp sales gate

Added additive events.whatsapp_sales_enabled BOOLEAN NOT NULL DEFAULT FALSE.
The existing dashboard create/edit surface provides the deliberate toggle.
WhatsApp discovery requires a non-archived event, the gate, and an active
sellable WhatsApp offer. Sales.Checkout.start_checkout/3 rechecks the gate for
effective channel whatsapp immediately before the authoritative reservation
boundary. A stale disabled conversation returns a safe unavailable result
without creating a new order or hold. Existing orders, valid holds, payments,
issued tickets, and scanner truth are not invalidated by disabling new WhatsApp
entry.

### WH-H05: quantity authority

TicketOffer.max_per_order remains the sole business quantity ceiling. The
normalizer accepts positive multi-digit input, preserves 0 as Back, rejects
malformed/signed/decimal/leading-zero values and defensively bounds input size,
and leaves menu-state bounds to the state machine. The selected offer maximum
is rendered dynamically in English and Afrikaans. Final server-side checkout
validation independently enforces the offer maximum. No Event-wide quantity
authority was introduced; #419 remains deferred.

### WH-H06: mixed attendee-source proof

Added an integration regression for one event containing both a Tickera-origin
attendee and a fastcheck_sales attendee. It covers Tickera reconciliation,
mobile/scanner visibility, valid Sales scanning, Sales revocation/invalidation,
post-revocation scanning, distinct attendee IDs, preserved source/ticket
identity, and no cross-source overwrite. The exact-head Postgres/Redis suite
passed; no scanner/source collision was introduced by this implementation.

### WH-H07 and WH-H08

.github/workflows/ci.yml explicitly provisions Postgres 15 and Redis 7 and
runs warnings-as-errors compilation, format verification, Credo strict,
Dialyzer, Sobelow, migrations, and the full test suite. Caching is constrained
to dependencies with a versioned key to avoid stale compiled code; no release
gate was removed.

Existing VS-24E and operational runbooks/evidence templates now distinguish
provider acceptance from actual Meta status, document callback evidence and
failed-status visibility, WABA/phone scope, protected-value redaction, event
disable/stale checkout, multi-digit quantity, mixed sources, and ambiguous
ticket-link transport. External Meta and Paystack verification remains clearly
manual; mocks are not claimed as provider success.

## Exact migrations

1. priv/repo/migrations/20260901090000_add_whatsapp_sales_hardening_fields.exs
   adds the additive, non-null, default-false events.whatsapp_sales_enabled
   field.
2. priv/repo/migrations/20260901091000_harden_whatsapp_delivery_attempt_lifecycle.exs
   adds provider acceptance/status/read/failure evidence fields, explicit
   lifecycle constraints, immutable status-evidence storage/indexes, a
   deterministic legacy sent -> provider_accepted backfill, duplicate-WAMID
   preflight abort, scoped partial uniqueness, and a non-destructive rollback
   mapping richer states to the legacy vocabulary before restoring its
   constraint.

Both migrations are additive/guarded and do not delete business records or
rewrite payment, ticket, inventory, scanner, or attendee authority.

## Security and protected values

Preserved raw-body Meta signature verification, Paystack signature verification,
payment verification, ticket issuance idempotency, scanner/admission authority,
inventory authority, and attendee-source authority. No new logging/evidence path
records raw phone, email, wa_id, recipient ID, customer text, raw provider
payload, Meta/Paystack secret, access code, payment URL, secure ticket URL,
delivery token/hash, QR secret, OTP, or protected raw struct. Sobelow passed and
manual source/diff review found no new protected-value leakage.

The Codex Security diff workbench was started for the working-tree diff
(scanId 3bfabdc8-52f7-4b20-9e03-7044e3d72fac) and the architecture review was
completed. Its artifact root later became unavailable and TAC reported the
security connector was not connected. No canonical Codex Security report or
finding is claimed; this is a tooling residual, not a security approval.

## Verification and release gates

### Focused tests and static checks

- Pure hardening tests that do not require the repository database alias passed
  with zero failures before the final database-backed exact-head run. They cover
  runtime configuration, provider status, webhook scope/verifier, input
  normalization, dynamic menu rendering, client/config redaction, provider
  boundary, resource skeletons, and migration compatibility.
- env MIX_ENV=test mix format --check-formatted: PASS.
- env MIX_ENV=test mix compile --warnings-as-errors: PASS.
- env MIX_ENV=test mix credo --strict: PASS, no issues.
- env MIX_ENV=test mix sobelow --exit --compact: PASS.
- git diff --check: PASS.
- Local database-backed focused tests could not complete because Postgres
  localhost:5434 and Redis localhost:6380 were unavailable. The attempted
  changed-test run reached setup and failed only because FastCheck.Repo could
  not connect; the exact-head CI run below supplied the required service-backed
  evidence.

### Local release aliases

- mix precommit: BLOCKED at mix ecto.create after dependency resolution,
  warnings-as-errors compilation, formatting, and Credo passed; Postgres at
  localhost:5434 refused the connection.
- mix ci: the host Elixir 1.19.3/OTP 28 run reports the known host-toolchain
  Dialyzer diagnostics and cannot reach the local database. This is not the
  release result: the pinned exact-head workflow below passed on Elixir 1.17.3
  / OTP 26.2 with Postgres 15 and Redis 7.

### Exact-head GitHub CI evidence

- Hardening commit: 9f113815ff1a2176c99e18cfa592fb4a3cb47a3e.
- Workflow run: https://github.com/JCSchoeman96/FastCheckin/actions/runs/33598785965.
- Job: Test (Elixir 1.17.3 OTP 26.2) (100147671561).
- Required service setup: Postgres 15 and Redis 7 started and became healthy.
- Compile with warnings-as-errors, format, Credo strict, Dialyzer, Sobelow,
  database migration, and full tests: PASS.

The earlier Dialyzer blocker was resolved by the minimal pre-existing warning
fixes tracked in bd-v8v; the Dialyzer gate was not weakened or bypassed.

### Separate dependency-security PR

The requested HIGH Hex advisory/tooling remediation is isolated in PR #463
(https://github.com/JCSchoeman96/FastCheckin/pull/463), based on the hardening
line and intentionally not merged into this PR. It upgrades the affected
Ash/AshPostgres, Phoenix/Plug/Cowboy/Bandit, Ecto/Postgrex, HPAX/Mint, Req,
Sentry, Credo, and Sobelow lines; removes unused Hackney and Mishka
Chelekom/html sanitizer paths; and keeps Req on the highest compatible fixed
line for the current Swoosh constraint. Its exact pinned workflow run
33597703368 (https://github.com/JCSchoeman96/FastCheckin/actions/runs/33597703368)
(job 100144409191) passed every required gate, including Dialyzer, Sobelow,
migrations, and the full test suite. It remains open/unmerged and should be
reviewed/rebased as needed when the hardening PR is integrated.

## Files changed against the reviewed baseline

The hardening PR compare is 15 commits ahead, 0 behind, and reports 90 changed
files:

~~~text
.github/workflows/ci.yml
config/config.exs
config/runtime.exs
docs/fastcheck_sales/feature_packs/0041_VS-20_whatsapp-delivery-window-handling/VS-20-FEATURE_PACK.md
docs/fastcheck_sales/feature_packs/0049_VS-24E_production-checkout-ticket-delivery-smoke-test/ACCEPTANCE_CHECKLIST.md
docs/fastcheck_sales/feature_packs/0049_VS-24E_production-checkout-ticket-delivery-smoke-test/EVIDENCE_TEMPLATE.md
docs/fastcheck_sales/feature_packs/0049_VS-24E_production-checkout-ticket-delivery-smoke-test/TOON_PROMPTS.md
docs/fastcheck_sales/handoffs/WHATSAPP_PRODUCTION_HARDENING_IMPLEMENTATION_HANDOFF.md
docs/fastcheck_sales/runbooks/INCIDENT_RESPONSE.md
docs/fastcheck_sales/runbooks/POST_LAUNCH_MONITORING.md
docs/fastcheck_sales/runbooks/SANDBOX_DRESS_REHEARSAL.md
docs/fastcheck_sales/runbooks/VS-23C_FINAL_WHATSAPP_LAUNCH_RUNBOOK.md
docs/fastcheck_sales/runbooks/VS-24E_FAILURE_MATRIX.md
docs/fastcheck_sales/runbooks/VS-24E_PRODUCTION_CHECKOUT_TICKET_DELIVERY_SMOKE_TEST.md
docs/fastcheck_sales/runbooks/VS-24E_PRODUCTION_LOW_VALUE_SMOKE.md
docs/fastcheck_sales/state_machines/DELIVERY_ATTEMPT_STATE_MACHINE.md
lib/fastcheck/events.ex
lib/fastcheck/events/event.ex
lib/fastcheck/messaging/whatsapp/client.ex
lib/fastcheck/messaging/whatsapp/config.ex
lib/fastcheck/messaging/whatsapp/conversation_state_machine.ex
lib/fastcheck/messaging/whatsapp/copy.ex
lib/fastcheck/messaging/whatsapp/delivery_status_reconciler.ex
lib/fastcheck/messaging/whatsapp/input_normalizer.ex
lib/fastcheck/messaging/whatsapp/menu_renderer.ex
lib/fastcheck/messaging/whatsapp/provider_status.ex
lib/fastcheck/messaging/whatsapp/response.ex
lib/fastcheck/messaging/whatsapp/webhook_scope.ex
lib/fastcheck/runtime_configuration.ex
lib/fastcheck/sales.ex
lib/fastcheck/sales/admin_refunds.ex
lib/fastcheck/sales/admin_revocations.ex
lib/fastcheck/sales/audit_views.ex
lib/fastcheck/sales/checkout.ex
lib/fastcheck/sales/checkout_expiry.ex
lib/fastcheck/sales/checkout_session.ex
lib/fastcheck/sales/delivery_attempt.ex
lib/fastcheck/sales/inventory/health.ex
lib/fastcheck/sales/inventory/reconciler.ex
lib/fastcheck/sales/inventory/recovery.ex
lib/fastcheck/sales/payments/payment_outcome_handler.ex
lib/fastcheck/sales/payments/payment_outcomes.ex
lib/fastcheck/sales/payments/payment_verification.ex
lib/fastcheck/sales/sandbox_fixtures.ex
lib/fastcheck/sales/state_transition_support.ex
lib/fastcheck/sales/ticket_resend_challenge.ex
lib/fastcheck/tickets/artifact_resolver.ex
lib/fastcheck/tickets/pdf_ticket.ex
lib/fastcheck/tickets/pdf_ticket/qr_code.ex
lib/fastcheck/tickets/resend/eligibility.ex
lib/fastcheck/tickets/revocation.ex
lib/fastcheck/workers/send_whatsapp_payment_link_worker.ex
lib/fastcheck/workers/send_whatsapp_ticket_link_worker.ex
lib/fastcheck_web/controllers/sales/ticket_pdf_controller.ex
lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex
lib/fastcheck_web/live/dashboard_live.ex
lib/fastcheck_web/live/sales/audit_timeline_live.ex
lib/fastcheck_web/live/sales/order_show_live.ex
priv/repo/migrations/20260901090000_add_whatsapp_sales_hardening_fields.exs
priv/repo/migrations/20260901091000_harden_whatsapp_delivery_attempt_lifecycle.exs
test/fastcheck/messaging/whatsapp/boundary_test.exs
test/fastcheck/messaging/whatsapp/client_test.exs
test/fastcheck/messaging/whatsapp/config_test.exs
test/fastcheck/messaging/whatsapp/conversation_state_machine_test.exs
test/fastcheck/messaging/whatsapp/delivery_status_reconciler_test.exs
test/fastcheck/messaging/whatsapp/e2e/whatsapp_paid_core_test.exs
test/fastcheck/messaging/whatsapp/event_sales_gate_test.exs
test/fastcheck/messaging/whatsapp/input_normalizer_test.exs
test/fastcheck/messaging/whatsapp/log_redaction_test.exs
test/fastcheck/messaging/whatsapp/menu_renderer_test.exs
test/fastcheck/messaging/whatsapp/payment_flow_test.exs
test/fastcheck/messaging/whatsapp/provider_status_test.exs
test/fastcheck/messaging/whatsapp/resend_ticket_e2e_test.exs
test/fastcheck/messaging/whatsapp/webhook_scope_test.exs
test/fastcheck/runtime_configuration_test.exs
test/fastcheck/sales/checkout_expiry_test.exs
test/fastcheck/sales/conversation_resource_migrations_test.exs
test/fastcheck/sales/delivery_attempt_migration_compatibility_test.exs
test/fastcheck/sales/e2e/revocation_scanner_visibility_test.exs
test/fastcheck/sales/sandbox_fixtures_test.exs
test/fastcheck/sales/ticket_and_delivery_resource_migrations_test.exs
test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs
test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs
test/fastcheck/workers/send_whatsapp_payment_link_worker_test.exs
test/fastcheck/workers/send_whatsapp_ticket_link_worker_test.exs
test/fastcheck/workers/whatsapp_inbound_worker_test.exs
test/fastcheck_web/browser_auth_test.exs
test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs
test/support/sales_checkout_fixtures.ex
test/support/sales_e2e_fixtures.ex
test/support/whatsapp_webhook_test_support.ex
~~~

## Residual risks and manual VS-24E actions

- Manually verify the Meta business portfolio, WABA, registered phone, token
  type/permissions, templates, webhook subscription, and phone two-step
  verification. sandbox_mode is configuration intent, not provider-isolation
  proof.
- Run the separately authorized VS-24E real sandbox dress rehearsal: real
  signed Meta callbacks, in-scope/out-of-scope checks, low-value sandbox
  checkout, Paystack verification, ticket issuance, provider status evidence,
  failed-status operator handling, event disable/stale checkout, multi-digit
  quantity, secure ticket behavior, mixed-source scanning, redacted evidence,
  and explicit owner decision.
- Local mix precommit and mix ci remain environment-limited as described above;
  the pinned exact-head GitHub gates are the release evidence.
- PR #463 still requires review and integration sequencing; its exact-head
  gates pass, but it is intentionally separate from this hardening PR.

## Scope firewall and deferred issues

No wallet work, wallet buttons, public-web checkout, customer PDF attachment
delivery, new PDF architecture, abandoned-checkout reminders, earlier PII
collection, CRM/profile work, broad TicketOffer admin management (#434), combined
dashboard (#435), broad event-edit redesign (#436), archive deletion (#437),
scanner architecture redesign, Android UI redesign, new payment provider,
Paystack authority redesign, inventory redesign, ticket issuance redesign,
WordPress/Tickera rewrite, unrelated dependency upgrades, or large design-system
changes entered the hardening diff. Android files were not changed.

Deferred/future GitHub issues remain deferred and were not automatically closed.
The quantity work deliberately keeps TicketOffer.max_per_order as the only
business ceiling; #419 is not implemented as a second Event-wide authority.

## Final release status

PR OPENED; NOT MERGED.

CODE HARDENING: COMPLETE
AUTOMATED RELEASE GATES: PASS
SANDBOX DRESS REHEARSAL: NOT YET IMPLIED
PRODUCTION: NOT YET IMPLIED
