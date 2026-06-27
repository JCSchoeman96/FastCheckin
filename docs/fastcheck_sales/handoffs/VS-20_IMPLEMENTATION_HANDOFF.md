# VS-20 Implementation Handoff

## Status

Merged.

PR: #406 — feat(whatsapp): enforce VS-20 delivery window  
Merge commit: `83d06a861dea3cf5d5c19e6e4949368b6a504aca`  
Merged at: 2026-06-27T08:23:32Z  
Branch: `vs-20-whatsapp-delivery-window`

## What Changed

VS-20 added Meta 24-hour delivery-window selection for WhatsApp ticket-link sends
and extended the existing VS-19 `SendWhatsAppTicketLinkWorker` to use it.

Pure modules `DeliveryWindow` and `DeliveryPolicy` decide whether a ticket send
uses a session text message (inside 24h), an approved `ticket_ready_*` template
(outside 24h), or `fallback_required` when the outside-window template is
unavailable. The worker records `within_whatsapp_window`, template name, fallback
channel, and manual-review state on `DeliveryAttempt`.

Ticket-link outbound dedupe now uses a separate 24-hour TTL
(`:whatsapp_ticket_delivery_dedupe_ttl_seconds`, default 86_400), distinct from
the 600-second payment-link dedupe TTL. The sales order operations page shows a
bounded, masked delivery-attempt summary for support visibility.

No new delivery worker, queue, email fallback worker, Paystack changes, ticket
issuance, scanner/mobile/Android changes, or inbound conversation changes were
added.

## Files Changed

- `lib/fastcheck/messaging/whatsapp/delivery_window.ex` — pure 24-hour Meta
  customer-service window check from `last_message_at`.
- `lib/fastcheck/messaging/whatsapp/delivery_policy.ex` — selects
  `:session_message`, `:template_message`, or `:fallback_required` for ticket
  delivery; uses existing `TemplateCatalog.fetch/1`.
- `lib/fastcheck/workers/send_whatsapp_ticket_link_worker.ex` — applies delivery
  policy before send; session text via `Client.send_text/3`, outside-window via
  `Client.send_template/3`; records `mark_fallback_required` and
  `mark_manual_review`; uses 24h ticket dedupe TTL.
- `lib/fastcheck/sales/delivery_attempt.ex` — adds `mark_manual_review` update
  action alongside existing `mark_fallback_required`.
- `lib/fastcheck/sales/admin_refunds.ex` — `bounded_delivery_attempt_summaries/2`
  for masked order-operations context.
- `lib/fastcheck_web/live/sales/order_show_live.ex` — renders bounded delivery
  attempt rows (status, window, template, fallback, reason).
- `config/config.exs` — registers
  `:whatsapp_ticket_delivery_dedupe_ttl_seconds` (86_400).
- `test/fastcheck/messaging/whatsapp/delivery_window_test.exs` — 24h boundary,
  nil timestamp, and clock-skew behavior.
- `test/fastcheck/messaging/whatsapp/delivery_policy_test.exs` — session vs
  template vs fallback selection by language and template availability.
- `test/fastcheck/workers/send_whatsapp_ticket_link_worker_test.exs` — session
  send inside window, template send outside window, 24h dedupe TTL, manual review
  on auth errors, token redaction in logs/audit.
- `test/fastcheck/messaging/whatsapp/boundary_test.exs` — VS-20 policy modules
  stay pure (no Sales, Oban, Repo, Redis, or provider HTTP).
- `test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs` —
  `mark_manual_review` action boundary alignment.
- `test/fastcheck_web/live/sales/order_show_live_test.exs` — masked delivery
  attempt summary on order show page.
- `test/support/whatsapp_webhook_test_support.ex` — test support for delivery
  window scenarios.

## Contracts Now Available

- `FastCheck.Messaging.WhatsApp.DeliveryWindow.inside?/2` — authoritative pure
  24-hour window check; `nil` last message is outside window.
- `FastCheck.Messaging.WhatsApp.DeliveryPolicy.select_ticket_delivery/2` —
  returns `%{
    mode: :session_message | :template_message | :fallback_required,
    within_whatsapp_window: boolean(),
    template_key: atom() | nil,
    template: map() | nil,
    fallback_channel: String.t() | nil,
    failure_reason: String.t() | nil
  }`; English maps to `:ticket_ready_en`, all other languages default to
  `:ticket_ready_af`.
- `SendWhatsAppTicketLinkWorker` — still the only ticket-link outbound path; now
  chooses session text vs approved template vs fallback before provider send.
- `DeliveryAttempt.within_whatsapp_window` — populated on ticket-link creates.
- `DeliveryAttempt.mark_manual_review` — used for Meta auth/validation failures;
  sets `fallback_channel: "manual_review"`.
- `DeliveryAttempt.mark_fallback_required` — used when outside-window template is
  unavailable; sets `fallback_channel: "manual_review"` and
  `failure_reason: "whatsapp_template_unavailable"`.
- `:whatsapp_ticket_delivery_dedupe_ttl_seconds` — 24h ticket send dedupe (default
  86_400); payment-link dedupe remains `:whatsapp_outbound_dedupe_ttl_seconds`
  (600).
- `AdminRefunds.get_order_operations_context/1` — includes
  `:delivery_attempt_rows` with masked recipient excluded from UI summary fields.
- `TemplateCatalog` — existing static catalog; VS-20 consumes
  `:ticket_ready_af` and `:ticket_ready_en` entries only for ticket delivery.

## Decisions Applied

- Reuse existing VS-19 `SendWhatsAppTicketLinkWorker`; no new delivery worker or
  Oban queue.
- Keep provider HTTP inside VS-16 `Client`; policy modules stay pure.
- Session message inside 24h; approved utility template outside 24h.
- Missing outside-window template moves to `fallback_required` with
  `manual_review` fallback channel (not email send).
- Meta auth/validation errors discard to `:manual_review`; retryable provider
  errors mark `failed` and release dedupe for Oban retry.
- Separate 24h ticket-delivery dedupe TTL from 600s payment-link dedupe TTL.
- Ticket-link audit stores redacted recipient and generic failure messages; no
  plaintext ticket URL or token in durable audit columns.
- Afrikaans-first template default; English uses `fastcheck_ticket_ready_en`.
- `event_scoped_first` unchanged; workers use system actor.
- No payment-link delivery-window enforcement in this slice (ticket-link only).

## Boundaries Still Enforced

- No email fallback worker or Swoosh/Mailer ticket delivery.
- No new Oban worker namespace for ticket sends.
- No Paystack verification, refunds, or webhook handling.
- No ticket issuance via `Tickets.Issuer` from WhatsApp modules.
- No scanner, attendee sync, mobile API, or Android changes.
- No Redis inventory / `ReservationLedger` mutation from WhatsApp modules.
- No inbound webhook or conversation menu changes.
- No `delivered` webhook/status lifecycle on `DeliveryAttempt`.
- No Meta template catalog sync from provider API.
- `DeliveryPolicy` and `DeliveryWindow` must not call Sales, Ash, Oban, Repo,
  Redis, or provider HTTP (boundary test enforced).
- VS-16 provider modules remain decoupled from Sales/Ash/Oban per existing
  boundary test.

## Tests Added Or Updated

- `test/fastcheck/messaging/whatsapp/delivery_window_test.exs` — inside/outside
  24h boundary, nil timestamp, future timestamp tolerance.
- `test/fastcheck/messaging/whatsapp/delivery_policy_test.exs` — session vs
  Afrikaans/English template vs fallback when template missing.
- `test/fastcheck/workers/send_whatsapp_ticket_link_worker_test.exs` — session
  text inside window; template send outside window; 24h dedupe TTL; revoked
  ticket guard; masked failure audit; manual review on Meta 401; retry after
  dedupe release; token redaction in logs.
- `test/fastcheck/messaging/whatsapp/boundary_test.exs` — VS-20 policy module
  purity guard.
- `test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs` —
  `mark_manual_review` action present.
- `test/fastcheck_web/live/sales/order_show_live_test.exs` — safe delivery
  attempt summary without raw phone, provider payload, or ticket token material.

## Verification Reported

From PR #406 body and merge commit:

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test test/fastcheck/messaging/whatsapp/delivery_window_test.exs test/fastcheck/messaging/whatsapp/delivery_policy_test.exs test/fastcheck/workers/send_whatsapp_ticket_link_worker_test.exs test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs test/fastcheck_web/live/sales/order_show_live_test.exs test/fastcheck/messaging/whatsapp/boundary_test.exs`
- `mix test test/fastcheck/messaging/whatsapp/`
- `mix test test/fastcheck/workers/send_whatsapp_payment_link_worker_test.exs`
- `mix test test/fastcheck/sales/ticket_and_delivery_resource_migrations_test.exs`
- `mix test test/fastcheck/sales/ticket_page_test.exs`
- `mix test test/fastcheck/tickets/`
- `mix test` — 1014 tests, 0 failures, 4 skipped
- `mix precommit` — 1014 tests, 0 failures, 4 skipped
- Merge commit notes GitHub CI run 911 passed on
  `1ebe535cd582b05a352788b2e0e646ba05b27ed1`

## Known Limitations

- No email fallback delivery; unavailable template or hard provider failures
  route to `manual_review` / `fallback_required` audit only.
- No automatic follow-up worker after `fallback_required`; job discards with
  `:fallback_required`.
- Payment-link sends do not yet apply 24-hour window or template selection.
- `DeliveryAttempt.delivered_at` and Meta delivery-status webhooks are not wired.
- Template catalog is static local config; no runtime Meta template approval
  sync or cache.
- No recipient rate-limit Redis keys from the planning pack.
- No dedicated `ticket_message_builder.ex`; worker uses `TicketLinkRenderer` and
  inline template components.

## Next Agent Guidance

**Reuse:**

- `DeliveryWindow.inside?/2` and `DeliveryPolicy.select_ticket_delivery/2` for
  any new WhatsApp outbound send that must respect Meta session windows.
- `SendWhatsAppTicketLinkWorker` as the only ticket-link send path; extend here
  rather than creating parallel workers.
- `TemplateCatalog.fetch/1` for approved template names and language codes.
- `DeliveryAttempt` create/mark actions and VS-21A `Redactor` for audit fields.
- `Dedupe.claim_send_ticket_link/3` with the 24h ticket TTL config key.
- `AdminRefunds.get_order_operations_context/1` delivery rows for ops visibility.

**Do not:**

- Add provider HTTP to `DeliveryPolicy` or `DeliveryWindow`.
- Bypass outbound dedupe or create a second ticket-link worker namespace.
- Store plaintext ticket URLs or delivery tokens in `DeliveryAttempt` audit
  columns or logs.
- Send ticket links before order is `ticket_issued` and `TicketIssue` is `issued`
  with `revoked_at: nil`.
- Recreate 24-hour window logic outside `DeliveryWindow`.
- Change payment-link worker behavior without an explicit slice decision.

**Authoritative tests to keep green:**

- `test/fastcheck/messaging/whatsapp/delivery_window_test.exs`
- `test/fastcheck/messaging/whatsapp/delivery_policy_test.exs`
- `test/fastcheck/workers/send_whatsapp_ticket_link_worker_test.exs`
- `test/fastcheck/messaging/whatsapp/boundary_test.exs`
- `test/fastcheck_web/live/sales/order_show_live_test.exs`
- `test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs`
- full `mix precommit` before merge

## Next Slice

Recommended next slice:  
VS-22 — End-to-End Sandbox Tests

Entry condition:

- VS-16 through VS-20 merged on `main` with WhatsApp inbound/outbound,
  payment/ticket handoff, and delivery-window handling tests green.
- Selected launch scope (`whatsapp_first_paid_core`) happy path and critical
  failure paths exist for E2E coverage.
- VS-22 must prove full-path behavior for the selected launch scope; it must not
  rewrite delivery policy, checkout, payment verification, or issuance contracts.
