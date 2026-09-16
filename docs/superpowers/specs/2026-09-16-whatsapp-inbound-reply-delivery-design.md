# WhatsApp inbound reply delivery design

## Goal

Make a computed WhatsApp reply durable across retryable Meta failures without
replaying the inbound conversation transition or its business effects.

## Storage choice

Use the existing sensitive `sales_conversations.state_data` JSONB checkpoint.
The existing `DeliveryAttempt` resource is shaped around order and ticket
delivery, so using it for an arbitrary inbound conversation reply would require
new nullable relationships and payload fields. That would be a larger domain
change than this issue needs.

The state machine writes the pending reply in the same durable checkpoint update
that records the provider inbound message as handled. The reply body is
encrypted with `FastCheck.Crypto` before it enters `state_data`.

The nested value has this shape:

```text
state_data["pending_reply"] = %{
  "ciphertext" => encrypted reply body,
  "provider_message_id" => inbound provider message ID,
  "status" => "reply_pending" | "reply_retryable" | "reply_sent" | "reply_failed",
  "attempt_count" => non-negative integer,
  "computed_at" => ISO8601 timestamp,
  "last_attempt_at" => ISO8601 timestamp or nil,
  "failure_class" => stable internal class or nil
}
```

The ciphertext is cleared for both terminal outcomes. A successful reply keeps
only the terminal status metadata. A permanent failure also sets
`needs_human` to `true` and uses a stable `handoff_reason`, such as
`whatsapp_reply_auth_failure`, `whatsapp_reply_validation_failure`, or
`whatsapp_reply_retry_exhausted`. Provider prose never enters that field.

## Named domain actions

`FastCheck.Sales.Conversation` exposes narrowly named update actions:

- `store_pending_reply` records a computed reply and preserves every unrelated
  `state_data` key.
- `mark_reply_retryable` records a retryable transport outcome and leaves the
  encrypted reply available for the next Oban execution.
- `mark_reply_sent` records the terminal successful outcome and clears the
  ciphertext.
- `mark_reply_failed` records the terminal permanent outcome, clears the
  ciphertext, and marks the conversation for operator attention.

These actions do not change `Conversation.state` and do not expose a generic
status mutation action. They validate the nested reply identity and current
delivery status before changing it.

## Worker flow

The worker first loads the conversation and checks for a nested pending or
retryable reply. If one exists, it decrypts and sends that body directly. This
path has no access to `ConversationStateMachine.handle_inbound/2`.

If no pending reply exists, the worker decrypts the inbound customer message,
builds the command, and calls the state machine once. A reply-producing result
already contains the durable nested pending reply written by the state-machine
checkpoint. The worker sends that exact stored body and records the provider
outcome.

Retryable provider responses return an Oban error after recording
`reply_retryable`. Permanent provider responses record `reply_failed` and are
discarded. When the final Oban retry still returns a retryable response, the
worker records `reply_failed` with `whatsapp_reply_retry_exhausted` before
discarding the job. Business state and business effects are never rolled back.

Duplicate provider webhooks remain filtered by the existing Redis inbound
dedupe and Conversation provider-message checkpoint. Duplicate Oban execution
sees the durable reply state and resends it without invoking the state machine.

## Concurrency and delivery semantics

The existing Oban uniqueness and inbound dedupe remain in place. The database
checkpoint is the authority; Redis remains an acceleration/dedupe layer only.
State updates merge the reply key into the loaded checkpoint rather than
replacing the whole map. A provider timeout can leave Meta's acceptance
unknown, so transport is at-least-once. The invariant is exactly-once business
processing and one durable logical reply, not mathematically exactly-once
delivery by an external provider that offers no send idempotency guarantee.

## Verification

Behavior tests will cover:

- first business processing plus retryable send failure;
- successful retry of the stored reply without a second state-machine call;
- duplicate webhook/job behavior;
- checkout, payment, inventory, and OTP idempotency boundaries;
- permanent provider failure and exhausted retries becoming operator-visible;
- absence of plaintext reply bodies, customer values, URLs, tokens, and raw
  provider values from job arguments and logs.

The change excludes payment-link policy work, Paystack, checkout semantics,
ticket issuance, scanner behavior, revocation, Android, and Meta configuration.
