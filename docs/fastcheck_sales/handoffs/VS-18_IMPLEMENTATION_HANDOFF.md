# VS-18 Implementation Handoff

## Status

Merged.

PR: #402 — feat(whatsapp): add VS-18 number-only conversation flow  
Merge commit: `0f78a47b88de9a19457b4c742e6169467859651e`  
Merged at: 2026-06-26T18:21:21Z  
Branch: `vs-18-whatsapp-number-only-flow`

## What Changed

VS-18 added the Afrikaans-first WhatsApp number-only conversation adapter from
first inbound message through order confirmation and `Checkout.start_checkout/3`.
The flow covers language selection, main menu, event/offer/quantity selection,
buyer name and optional email collection, and transitions to `awaiting_payment`
after a successful checkout start.

`WhatsAppInboundWorker` now decrypts `text_body_encrypted` from sanitized Oban
args, loads phone/`wa_id` from the durable `Conversation` row, runs the state
machine, and sends safe outbound text via the VS-16 `Client`. Redis session
hashes store only PII-safe flow fields; buyer name and email stay in durable
`Conversation.state_data` only.

No migrations, Paystack calls, payment-link messages, ticket issuance,
`DeliveryAttempt` creation, Redis inventory mutation, or scanner/mobile/Android
changes were added.

## Files Changed

- `lib/fastcheck/messaging/whatsapp/conversation_state_machine.ex` — inbound
  dispatch, menu progression, duplicate inbound suppression, checkout start via
  `FastCheck.Sales.Checkout`, and Redis session refresh.
- `lib/fastcheck/messaging/whatsapp/input_normalizer.ex` — number-only input
  parsing (`1`–`9`, `0` back, `#` restart, `help`, `stop`, free text).
- `lib/fastcheck/messaging/whatsapp/menu_renderer.ex` — customer-facing menu text
  for each conversation step.
- `lib/fastcheck/messaging/whatsapp/copy.ex` — Afrikaans-first and English copy
  strings.
- `lib/fastcheck/messaging/whatsapp/flow_result.ex` — state-machine result struct
  (`conversation`, `response_body`, `session_fields`, `send_reply?`).
- `lib/fastcheck/messaging/whatsapp/session_store.ex` — `put_flow_session/4` and
  bounded Redis flow fields (no buyer name/email).
- `lib/fastcheck/sales/conversation.ex` — VS-18 named update actions with
  audited `StateTransition` recording.
- `lib/fastcheck/sales/ticket_offer.ex` — field policy now allows
  `:customer_session` actor for WhatsApp offer reads.
- `lib/fastcheck/workers/whatsapp_inbound_worker.ex` — decrypt encrypted body,
  run state machine, send outbound reply; Oban args remain sanitized.
- `lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex` — encrypt
  inbound text for Oban; fail closed and release dedupe on encryption failure.
- `test/fastcheck/messaging/whatsapp/conversation_state_machine_test.exs` — full
  number-only flow, checkout idempotency, Redis-loss recovery, invalid input.
- `test/fastcheck/messaging/whatsapp/input_normalizer_test.exs` — input parsing
  edge cases.
- `test/fastcheck/messaging/whatsapp/menu_renderer_test.exs` — menu copy and
  option rendering.
- `test/fastcheck/messaging/whatsapp/session_store_test.exs` — flow-field
  allowlist and PII exclusion.
- `test/fastcheck/sales/conversation_state_actions_test.exs` — named action
  state change plus sanitized transition audit.
- `test/fastcheck/sales/conversation_resource_skeleton_test.exs` — guards the
  exact VS-17 checkpoint plus VS-18 named mutating action set.
- `test/fastcheck/workers/whatsapp_inbound_worker_test.exs` — encrypted-body
  flow, outbound send, retry/idempotency behavior.
- `test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs` —
  encryption-failure fail-closed path.
- `test/fastcheck/messaging/whatsapp/boundary_test.exs` — VS-18 modules must not
  reference Paystack, ticket issuance, delivery, scanner, or mobile paths.
- `test/support/sales_boundary_allowlist.ex` — allowlist updates for new
  WhatsApp conversation modules.
- Historical `test/fastcheck/sales/vs_01e_boundary_test.exs`,
  `vs_01f_boundary_test.exs`, and `vs_01g_index_and_migration_verification_test.exs`
  — boundary allowlist alignment only.

## Contracts Now Available

- `FastCheck.Messaging.WhatsApp.ConversationStateMachine.handle_inbound/2` —
  authoritative VS-18 inbound handler; returns `{:ok, FlowResult.t()}`.
- `FastCheck.Messaging.WhatsApp.InputNormalizer.normalize/1` — bounded menu input
  normalization (`{:number, 1..9}`, `:back`, `:restart`, `:help`, `:stop`,
  `{:text, _}`, or error atoms).
- `FastCheck.Messaging.WhatsApp.MenuRenderer` and `Copy` — customer-facing
  Afrikaans-first menus and copy; default language `"af"`.
- `FastCheck.Messaging.WhatsApp.SessionStore.put_flow_session/4` — Redis hot
  state with allowlisted flow fields only:
  `selected_event_id`, `selected_offer_id`, `quantity`, `sales_order_id`,
  `order_public_reference`, `version`.
- `FastCheck.Sales.Conversation` named update actions:
  `start_language_selection`, `start_default_main_menu`, `select_language`,
  `choose_buy_tickets`, `select_event`, `select_ticket_type`, `submit_quantity`,
  `submit_buyer_name`, `submit_buyer_email`, `skip_optional_email_after_name`,
  `confirm_order`, `return_to_main_menu`, `cancel_conversation`,
  `handoff_conversation`, `mark_conversation_payment_pending`.
- Conversation states now driven by VS-18:
  `new`, `selecting_language`, `main_menu`, `selecting_event`,
  `selecting_ticket_type`, `collecting_quantity`, `collecting_buyer_name`,
  `collecting_email`, `confirming_order`, `awaiting_payment`, `payment_pending`,
  `cancelled`, `manual_review`.
- `FastCheck.Sales.Checkout.start_checkout/3` called from confirm with
  `source_channel: "whatsapp"` and idempotency key
  `whatsapp:conversation:{conversation_id}:checkout`.
- `FastCheck.Workers.WhatsAppInboundWorker` — decrypts `text_body_encrypted`,
  loads PII from `Conversation`, sends outbound via `Client.send_text/3`.
- Webhook enqueue now stores `text_body_encrypted` in Oban args; raw message
  body is not persisted in job args.
- `FastCheck.Sales.TicketOffer` reads allowed for
  `%{actor_type: :customer_session, allowed_event_ids: [event_id]}`.

## Decisions Applied

- Afrikaans-first number-only menus; English available via language selection.
- Slash-command shortcuts encoded in `InputNormalizer` (`0`, `#`, `help`, `stop`).
- Durable `Conversation.state_data` owns buyer PII; Redis session stores only
  allowlisted non-PII flow fields.
- VS-05 shared checkout core used directly; VS-05A not depended on.
- `event_scoped_first` via `customer_session` actor with `allowed_event_ids`.
- Checkout idempotency is per-conversation, not per provider message.
- Duplicate inbound with the same `provider_message_id` suppresses reply
  (`send_reply?: false`).
- Oban args remain sanitized; phone/`wa_id`/plaintext body excluded.
- Fail-closed text encryption before enqueue; dedupe released on encryption
  failure.
- No database migrations in this slice.

## Boundaries Still Enforced

- No Paystack initialization, payment links, or webhook handling in WhatsApp
  modules.
- No ticket issuance, secure ticket page links, or `DeliveryAttempt` creation.
- No Redis `ReservationLedger` / inventory mutation from WhatsApp modules.
- No `Attendee` mutation, scanner/mobile/Android changes, or admin/customer UI.
- Outbound messages do not include Paystack URLs or payment instructions beyond
  generic awaiting-payment copy.
- VS-16 provider modules (`Client`, `MessageBuilder`, etc.) remain decoupled from
  Sales/Ash/Oban per boundary test.
- `mark_conversation_payment_pending` action exists but VS-18 does not drive
  payment-pending transitions after checkout start (VS-19 scope).
- No new migrations or Ash resources beyond `Conversation` action extensions and
  `TicketOffer` policy alignment.

## Tests Added Or Updated

- `test/fastcheck/messaging/whatsapp/conversation_state_machine_test.exs` — happy
  path to `awaiting_payment`, one-order checkout idempotency, Redis-loss
  recovery from durable checkpoint, invalid-input menu repeat.
- `test/fastcheck/messaging/whatsapp/input_normalizer_test.exs` — digits,
  shortcuts, blank/too-long/invalid input.
- `test/fastcheck/messaging/whatsapp/menu_renderer_test.exs` — language prompt,
  main/event/offer menus, invalid-input wrapper.
- `test/fastcheck/messaging/whatsapp/session_store_test.exs` — bounded fields,
  flow-session PII exclusion.
- `test/fastcheck/sales/conversation_state_actions_test.exs` — audited named
  action with sanitized transition metadata.
- `test/fastcheck/sales/conversation_resource_skeleton_test.exs` — exact
  checkpoint plus VS-18 named action inventory.
- `test/fastcheck/workers/whatsapp_inbound_worker_test.exs` — encrypted-body
  end-to-end worker flow, sanitized `new/1`, retry does not re-advance state.
- `test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs` —
  encryption failure fails closed before enqueue.
- `test/fastcheck/messaging/whatsapp/boundary_test.exs` — VS-18 module isolation
  from payment/ticket/delivery/scanner/mobile tokens.

## Verification Reported

From PR #402 body and merge commit:

- `mix deps.get`
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test test/fastcheck/messaging/whatsapp/input_normalizer_test.exs test/fastcheck/messaging/whatsapp/menu_renderer_test.exs`
- `mix test test/fastcheck/messaging/whatsapp/session_store_test.exs test/fastcheck/sales/conversation_state_actions_test.exs`
- `mix test test/fastcheck/messaging/whatsapp/conversation_state_machine_test.exs`
- `mix test test/fastcheck/workers/whatsapp_inbound_worker_test.exs`
- `mix test test/fastcheck/messaging/whatsapp/ test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs test/fastcheck/workers/whatsapp_inbound_worker_test.exs`
- `mix test test/fastcheck/sales/conversation_resource_skeleton_test.exs test/fastcheck/sales/conversation_resource_migrations_test.exs test/fastcheck/sales/vs_01e_boundary_test.exs test/fastcheck/sales/vs_01f_policy_test.exs test/fastcheck/sales/ticket_offer_test.exs test/fastcheck/sales/ticket_offer_policy_test.exs test/fastcheck/sales/order_checkout_core_test.exs test/fastcheck/sales/checkout_idempotency_test.exs test/fastcheck/sales/checkout_policy_test.exs`
- `mix test`
- `mix precommit` — 984 tests, 0 failures, 4 skipped
- GitHub CI run 901 passed on `e11d4c2b07d8e658cb1d2c59132b6940e1b47971`

## Known Limitations

- `awaiting_payment` is the terminal VS-18 state; no Paystack link send, payment
  confirmation handling, or ticket delivery.
- `payment_pending`, `manual_review`, and post-checkout customer messaging are
  stubbed with generic copy only; VS-19 owns payment and ticket flow.
- Email collection accepts skip (`1`) but does not validate email format beyond
  the collecting step boundary.
- Event/offer menus cap at 9 options; archived events and events without active
  offers are excluded.
- `handoff_conversation` action exists but VS-18 does not route failures to
  manual review automatically.
- WhatsApp delivery-window policy (VS-20) not applied here.

## Next Agent Guidance

**Reuse:**

- `FastCheck.Messaging.WhatsApp.ConversationStateMachine` — extend for
  post-checkout states in VS-19; do not fork a second flow engine.
- `InputNormalizer`, `MenuRenderer`, and `Copy` for additional menu steps.
- `SessionStore.put_flow_session/4` allowlist pattern for any new hot-state
  fields (never put buyer PII in Redis).
- `Conversation` named actions and `StateTransition` audit trail for new state
  transitions.
- `WhatsAppInboundWorker` as the single inbound execution path.
- `Checkout.start_checkout/3` and checkout idempotency key
  `whatsapp:conversation:{id}:checkout` for order creation.
- VS-16 `Client` for outbound WhatsApp text.
- `test/support/whatsapp_webhook_test_support.ex` and existing WhatsApp test
  fixtures.

**Do not:**

- Bypass webhook signature verification, dedupe, or encrypted Oban args.
- Put plaintext message body, phone, or `wa_id` into Oban args, Redis hashes, or
  logs.
- Call Paystack, issue tickets, or create `DeliveryAttempt` records from VS-18
  modules.
- Query Sales tables directly from VS-16 provider modules.
- Depend on VS-05A secondary entry points for WhatsApp-first flow.
- Add forbidden `Conversation` mutating actions (skeleton test guards the
  inventory).
- Recreate inbound worker or checkpoint modules under new namespaces.

**Authoritative tests to keep green:**

- `test/fastcheck/messaging/whatsapp/conversation_state_machine_test.exs`
- `test/fastcheck/messaging/whatsapp/`
- `test/fastcheck/workers/whatsapp_inbound_worker_test.exs`
- `test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs`
- `test/fastcheck/sales/conversation_resource_skeleton_test.exs`
- `test/fastcheck/sales/conversation_state_actions_test.exs`
- full `mix precommit` before merge

## Next Slice

Recommended next slice:  
VS-19 — WhatsApp Payment and Ticket Flow

Entry condition:

- VS-18 merged on `main` with number-only flow reaching `awaiting_payment`,
  checkout start via `Checkout.start_checkout/3`, encrypted Oban args, and
  conversation/worker/boundary tests green.
- VS-07C payment failure handling, VS-11 secure ticket page, and VS-16 outbound
  client remain available unchanged.
- VS-19 may extend `ConversationStateMachine`, `MenuRenderer`, and
  `WhatsAppInboundWorker` for Paystack link handoff, payment-pending messaging,
  secure ticket page links, and resend flow; it must still use approved Sales
  facades and must not bypass checkout, payment verification, or issuance
  contracts.
