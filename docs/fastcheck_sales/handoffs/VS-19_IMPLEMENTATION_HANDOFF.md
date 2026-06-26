# VS-19 Implementation Handoff

## Status

Merged.

PR: #404 — feat(whatsapp): add VS-19 payment and ticket handoff  
Merge commit: `92d6a77de5b984b3fe8ff5062f3456459ec3b2e0`  
Merged at: 2026-06-26T21:09:05Z  
Branch: `vs-19-whatsapp-payment-ticket-flow`

## What Changed

VS-19 connected the VS-18 WhatsApp conversation flow to approved Sales checkout,
Paystack transaction initialization, and outbound WhatsApp delivery of payment and
secure ticket links.

Order confirmation now runs through `PaymentFlow`, which calls
`Checkout.start_checkout/3` when needed, initializes Paystack via
`TransactionInitialization.initialize_for_checkout_session/3`, transitions the
conversation to `payment_pending`, and enqueues outbound workers. Post-checkout
customer messages in payment-related states route through
`PaymentFlow.respond_to_status_request/2` for status copy and resend behavior.

Two Oban workers on the new `:whatsapp_outbound` queue send Paystack authorization
URLs and `/t/:token` secure ticket page links via the VS-16 WhatsApp `Client`.
Outbound Redis dedupe prevents duplicate sends; dedupe keys are released on
retryable provider failures so Oban retries can resend.

`DeliveryAttempt` was promoted minimally for WhatsApp audit: ticketless payment-link
attempts are allowed, and workers record `queued` → `sent` / `failed` transitions.
`TicketIssue.rotate_delivery_token_for_delivery` rotates a fresh delivery token
before each ticket-link send.

No payment verification, ticket issuance, scanner/mobile/Android changes, or Meta
24-hour delivery-window policy were added.

## Files Changed

- `lib/fastcheck/messaging/whatsapp/payment_flow.ex` — VS-19 orchestrator for
  checkout confirmation, Paystack initialization, payment-pending transitions,
  status responses, and worker enqueue; no provider HTTP or issuance calls.
- `lib/fastcheck/messaging/whatsapp/payment_status_renderer.ex` — Afrikaans-first
  and English customer copy for payment-link queued, missing email, payment
  pending, ticket preparing, manual review, and terminal order states.
- `lib/fastcheck/messaging/whatsapp/ticket_link_renderer.ex` — customer copy for
  secure ticket link send, sending-now, not-ready, and not-deliverable messages.
- `lib/fastcheck/messaging/whatsapp/conversation_state_machine.ex` — delegates
  `confirming_order` confirmation and post-checkout states to `PaymentFlow`;
  removes inline checkout-start-on-confirm from VS-18.
- `lib/fastcheck/messaging/whatsapp/dedupe.ex` — outbound dedupe
  `claim_send_payment_link/3`, `release_send_payment_link/2`,
  `claim_send_ticket_link/3`, `release_send_ticket_link/2`.
- `lib/fastcheck/workers/send_whatsapp_payment_link_worker.ex` — loads initialized
  `PaymentAttempt`, creates ticketless `DeliveryAttempt`, sends Paystack URL via
  `Client.send_text/3`, marks sent/failed.
- `lib/fastcheck/workers/send_whatsapp_ticket_link_worker.ex` — rotates delivery
  token, validates order/ticket deliverability, creates ticket-linked
  `DeliveryAttempt`, sends `/t/:token` link only.
- `lib/fastcheck/sales/conversation.ex` — wires `request_payment_email` action to
  `collecting_email` state transition.
- `lib/fastcheck/sales/delivery_attempt.ex` — `ticket_issue_id` nullable; existing
  `create_queued`, `mark_sent`, `mark_failed` actions used by workers.
- `lib/fastcheck/sales/ticket_issue.ex` — `list_issued_by_order` read and
  `rotate_delivery_token_for_delivery` update with audited token rotation.
- `priv/repo/migrations/20260626210000_allow_ticketless_whatsapp_delivery_attempts.exs`
  — nullable `ticket_issue_id` plus delivery-attempt listing index.
- `config/config.exs` — registers `:whatsapp_outbound` Oban queue and
  `:whatsapp_outbound_dedupe_ttl_seconds` (600).
- `test/fastcheck/messaging/whatsapp/payment_flow_test.exs` — checkout confirm,
  missing-email gate, status resend, ticket-link enqueue.
- `test/fastcheck/workers/send_whatsapp_payment_link_worker_test.exs` — single
  send, masked failure audit, dedupe release on retry.
- `test/fastcheck/workers/send_whatsapp_ticket_link_worker_test.exs` — token
  rotation, dedupe, revoked-ticket guard, masked failure audit, retry resend.
- `test/fastcheck/messaging/whatsapp/conversation_state_machine_test.exs` — full
  number-only flow through `payment_pending` and duplicate-confirm idempotency.
- `test/fastcheck/messaging/whatsapp/boundary_test.exs` — VS-19 modules must not
  call issuance, verification, scanner, or mobile authority paths.
- `test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs`,
  `ticket_and_delivery_resource_migrations_test.exs`,
  `conversation_resource_skeleton_test.exs`, `vs_01c_boundary_test.exs`,
  `vs_01d_boundary_test.exs`, `vs_01f_boundary_test.exs` — skeleton/migration
  boundary alignment for new actions and nullable delivery-attempt column.

## Contracts Now Available

- `FastCheck.Messaging.WhatsApp.PaymentFlow.confirm_checkout_from_conversation/2` —
  authoritative confirm path from `confirming_order`; requires buyer email,
  starts or reuses checkout, initializes Paystack, enqueues payment-link worker,
  transitions to `payment_pending`.
- `FastCheck.Messaging.WhatsApp.PaymentFlow.respond_to_status_request/2` —
  status/resend handler for `awaiting_payment`, `payment_pending`,
  `payment_received`, `ticket_issued`, `completed`, `manual_review`, `expired`,
  and `cancelled` conversation states.
- `FastCheck.Workers.SendWhatsAppPaymentLinkWorker` — Oban worker on
  `:whatsapp_outbound`; args: `conversation_id`, `sales_order_id`,
  `payment_attempt_id`; unique on conversation + order.
- `FastCheck.Workers.SendWhatsAppTicketLinkWorker` — Oban worker on
  `:whatsapp_outbound`; args: `conversation_id`, `sales_order_id`,
  `ticket_issue_id`; unique on conversation + ticket issue.
- `FastCheck.Messaging.WhatsApp.Dedupe.claim_send_payment_link/3` and
  `claim_send_ticket_link/3` — outbound send dedupe with configurable TTL
  (`:whatsapp_outbound_dedupe_ttl_seconds`, default 600s).
- `FastCheck.Sales.Conversation.request_payment_email` — returns customer to
  `collecting_email` when Paystack initialization requires email.
- `FastCheck.Sales.Conversation.mark_conversation_payment_pending` — now driven
  by VS-19 after successful initialization.
- `FastCheck.Sales.TicketIssue.list_issued_by_order/1` — read issued tickets for
  an order.
- `FastCheck.Sales.TicketIssue.rotate_delivery_token_for_delivery/1` — rotates
  hashed delivery token before WhatsApp ticket-link send.
- `sales_delivery_attempts.ticket_issue_id` nullable — payment-link attempts
  recorded without a ticket issue.
- Checkout idempotency key unchanged:
  `whatsapp:conversation:{conversation_id}:checkout`.
- Payment initialization via approved
  `TransactionInitialization.initialize_for_checkout_session/3` with
  `source_channel: "whatsapp"`.
- Ticket links use `DeliveryToken.generate/0` and `/t/:token` only; raw tokens
  are not stored in `DeliveryAttempt` audit fields.

## Decisions Applied

- WhatsApp is an interface/orchestration layer only; Sales/payment/ticket services
  remain authoritative.
- Paystack initialization through approved `TransactionInitialization` boundary,
  not raw client calls from `PaymentFlow`.
- Outbound sends through Oban workers and VS-16 `Client`, not synchronous inbound
  worker paths.
- Buyer email required before Paystack initialization; missing email returns
  customer to `collecting_email`.
- Redis outbound dedupe with release on retryable send failure (second commit
  `af1a444`).
- `DeliveryAttempt` audit stores redacted recipient and generic failure messages;
  no Paystack URL or plaintext ticket token in audit columns.
- Ticketless payment-link `DeliveryAttempt` rows allowed via migration.
- `event_scoped_first` via `customer_session` actor with `allowed_event_ids`.
- Afrikaans-first copy with English variants in renderers.
- No payment verification, ticket issuance, or order status mutation from WhatsApp
  modules.

## Boundaries Still Enforced

- No payment verification or webhook handling in WhatsApp modules.
- No ticket issuance via `Tickets.Issuer` from WhatsApp code.
- No `mark_paid_verified`, `mark_ticket_issued`, refund, or revocation from
  WhatsApp modules.
- No scanner, attendee sync, mobile API, or Android changes.
- No Paystack URL stored in `DeliveryAttempt` columns.
- No plaintext ticket token or authorization URL logged in audit/error fields.
- No Meta 24-hour delivery-window logic, utility templates, or email fallback
  (VS-20 scope).
- No Redis inventory / `ReservationLedger` mutation from WhatsApp modules.
- VS-16 provider modules (`Client`, `MessageBuilder`, etc.) remain decoupled from
  Sales/Ash/Oban per existing boundary test.
- No admin/customer web UI for WhatsApp delivery operations.

## Tests Added Or Updated

- `test/fastcheck/messaging/whatsapp/payment_flow_test.exs` — confirm initializes
  Paystack and enqueues payment worker without inline URL in immediate reply;
  missing email blocks initialization; awaiting-payment status reuses order;
  `ticket_issued` status enqueues ticket-link worker.
- `test/fastcheck/workers/send_whatsapp_payment_link_worker_test.exs` — single
  Paystack link send with masked `DeliveryAttempt`; failure audit excludes URL;
  dedupe release allows retry send.
- `test/fastcheck/workers/send_whatsapp_ticket_link_worker_test.exs` — fresh token
  rotation and `/t/:token` link only; duplicate job suppressed; revoked ticket
  discarded; failure audit excludes token hash; retry resend after dedupe
  release.
- `test/fastcheck/messaging/whatsapp/conversation_state_machine_test.exs` — full
  VS-18 menu path now ends in `payment_pending` on confirm; duplicate confirm
  creates one order.
- `test/fastcheck/messaging/whatsapp/boundary_test.exs` — VS-19 payment modules
  must not reference issuance, verification, scanner, or mobile authority
  tokens.
- Sales skeleton/migration boundary tests updated for nullable delivery-attempt
  column and new conversation/ticket-issue actions.

## Verification Reported

From PR #404 body and merge commit:

- `mix compile --warnings-as-errors`
- `mix test test/fastcheck/messaging/whatsapp/payment_flow_test.exs test/fastcheck/workers/send_whatsapp_payment_link_worker_test.exs test/fastcheck/workers/send_whatsapp_ticket_link_worker_test.exs test/fastcheck/messaging/whatsapp/boundary_test.exs test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs test/fastcheck/sales/ticket_and_delivery_resource_migrations_test.exs test/fastcheck/sales/conversation_resource_skeleton_test.exs test/fastcheck/sales/vs_01d_boundary_test.exs test/fastcheck/sales/vs_01f_boundary_test.exs`
- `mix test test/fastcheck/messaging/whatsapp/ test/fastcheck/workers/whatsapp_inbound_worker_test.exs test/fastcheck/workers/send_whatsapp_payment_link_worker_test.exs test/fastcheck/workers/send_whatsapp_ticket_link_worker_test.exs`
- `mix test test/fastcheck/sales/payments/ test/fastcheck/payments/paystack/`
- `mix test test/fastcheck/tickets/ test/fastcheck/sales/ticket_page_test.exs test/fastcheck_web/controllers/secure_ticket_controller_test.exs test/fastcheck_web/controllers/mobile/sync_controller_test.exs`
- `mix test`
- `mix precommit`
- Merge commit notes GitHub CI passed on `af1a444eeb2ebdd3d6976f6251eb43c11e3acce1`

## Known Limitations

- WhatsApp does not react to Paystack webhooks or advance order state after
  payment; downstream payment/issuance workers must still run through approved
  Sales paths.
- No automatic ticket-link send when issuance completes; customer must message
  again (or inbound automation must call status handler) while conversation is in
  a handled post-checkout state.
- No Meta 24-hour session window enforcement, template fallback, or email
  delivery fallback.
- `within_whatsapp_window` on `DeliveryAttempt` is not populated by VS-19
  workers.
- `mark_fallback_required` action exists on `DeliveryAttempt` but is not used yet.
- Payment-link body includes Paystack URL in the WhatsApp message only; it is not
  persisted in durable audit columns.
- Conversation confirm no longer stops at `awaiting_payment`; VS-19 confirm
  path goes directly to `payment_pending` after initialization.

## Next Agent Guidance

**Reuse:**

- `FastCheck.Messaging.WhatsApp.PaymentFlow` — extend for delivery-window and
  fallback behavior; do not fork a second payment orchestrator.
- `SendWhatsAppPaymentLinkWorker` and `SendWhatsAppTicketLinkWorker` as the
  only outbound send paths for payment and ticket links.
- `Dedupe.claim_send_*` / `release_send_*` pattern for any new outbound WhatsApp
  send types.
- `PaymentStatusRenderer` and `TicketLinkRenderer` for additional customer copy.
- `ConversationStateMachine` dispatch into `PaymentFlow` for post-checkout
  states.
- `TransactionInitialization`, `Checkout.start_checkout/3`, VS-16 `Client`, and
  `DeliveryAttempt` create/mark actions.
- `TicketIssue.rotate_delivery_token_for_delivery` before any new ticket-link
  resend path.

**Do not:**

- Call `Tickets.Issuer`, payment verification, or order paid/issued transitions
  from WhatsApp modules.
- Store Paystack URLs or plaintext delivery tokens in `DeliveryAttempt` audit
  fields or logs.
- Send ticket links before `TicketIssue` is `issued` and order is
  `ticket_issued`.
- Bypass outbound dedupe or Oban queues for provider sends.
- Put buyer PII into Redis session hashes (VS-18 allowlist still applies).
- Recreate payment/ticket send workers under new namespaces.

**Authoritative tests to keep green:**

- `test/fastcheck/messaging/whatsapp/payment_flow_test.exs`
- `test/fastcheck/workers/send_whatsapp_payment_link_worker_test.exs`
- `test/fastcheck/workers/send_whatsapp_ticket_link_worker_test.exs`
- `test/fastcheck/messaging/whatsapp/conversation_state_machine_test.exs`
- `test/fastcheck/messaging/whatsapp/boundary_test.exs`
- `test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs`
- `test/fastcheck/sales/conversation_resource_skeleton_test.exs`
- full `mix precommit` before merge

## Next Slice

Recommended next slice:  
VS-20 — WhatsApp Delivery Window Handling

Entry condition:

- VS-19 merged on `main` with payment-link and ticket-link workers, outbound
  dedupe, `DeliveryAttempt` audit, and WhatsApp payment/ticket handoff tests
  green.
- VS-16 outbound client and VS-11 secure ticket page remain unchanged and
  available.
- VS-20 may extend delivery workers and `DeliveryAttempt` for Meta 24-hour window
  logic, utility templates, email fallback, and `mark_fallback_required`; it must
  not rewrite checkout, payment verification, or issuance contracts.
