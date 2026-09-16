# WhatsApp Inbound Reply Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every computed WhatsApp inbound reply durable and retry-safe without replaying the Conversation business transition or its side effects.

**Architecture:** Extend the existing `FastCheck.Sales.Conversation` named-action boundary with four explicit delivery actions that merge a `pending_reply` lifecycle into sensitive `state_data`. The state machine encrypts and stores the reply in the same checkpoint that records the handled provider message; the worker sends an unresolved stored reply through a separate path and records retryable, sent, or permanent outcomes. Existing Redis inbound dedupe and Oban uniqueness remain acceleration and duplicate suppression only.

**Tech Stack:** Elixir, Phoenix, Ash 3.x, AshPostgres, Ecto/PostgreSQL JSONB, Oban, Req, ExUnit, existing `FastCheck.Crypto` encryption and WhatsApp client.

---

## Files and boundaries

- Modify `test/fastcheck/workers/whatsapp_inbound_worker_test.exs` with behavior-oriented red tests for the first failed send, stored-reply retry, duplicate execution, side-effect idempotency, terminal failures, retry exhaustion, and unsafe job/log output.
- Modify `test/fastcheck/sales/conversation_resource_skeleton_test.exs` so the resource contract explicitly permits only the four new named delivery actions in addition to the existing checkpoint and business transition actions.
- Modify `lib/fastcheck/sales/conversation.ex` to add `store_pending_reply`, `mark_reply_retryable`, `mark_reply_sent`, and `mark_reply_failed` as argument-driven named updates. Their custom changes must merge only the `pending_reply` key, preserve unrelated `state_data`, leave `state` unchanged, and enforce provider identity/status guards.
- Modify `lib/fastcheck/messaging/whatsapp/conversation_state_machine.ex` so a reply-producing result encrypts its response and calls `store_pending_reply` as part of the durable handled-message checkpoint. No reply body is persisted in plaintext.
- Modify `lib/fastcheck/workers/whatsapp_inbound_worker.ex` so it first delivers an unresolved stored reply without importing or calling `ConversationStateMachine` on that branch, and so provider failures update the named lifecycle. Retry exhaustion marks a stable operator-visible terminal failure before the Oban job is discarded.

No migration, new resource, Android change, Redis structure, Cachex/ETS cache, Paystack change, checkout change, ticket change, or Meta configuration change is part of this plan.

### Task 1: Add the regression contract first

**Files:**

- Modify: `test/fastcheck/workers/whatsapp_inbound_worker_test.exs`
- Modify: `test/fastcheck/sales/conversation_resource_skeleton_test.exs`

- [ ] **Step 1: Replace the current false-green retry test with the confirmed failure regression.**

  Keep the test in `FastCheck.Workers.WhatsAppInboundWorkerTest`, but change its contract from “no request on retry” to “the exact computed reply is sent on retry and the business state is unchanged.” The test should configure the request function with an `Agent` or an atomically incremented test-process counter so the first response is a 500 and the second is a 200. Use an encrypted inbound body of `"1"` from `selecting_language`, capture the first outbound body, and assert after the first execution that:

  ```elixir
  assert {:error, :whatsapp_send_retryable} = perform_job(WhatsAppInboundWorker, args)
  assert conversation_state(conversation_id) == "main_menu"

  {state_data, _needs_human, _handoff_reason} = conversation_delivery_data(conversation_id)
  assert state_data["last_handled_inbound_message_id"] == args["provider_message_id"]
  assert state_data["pending_reply"]["status"] == "reply_retryable"
  assert state_data["pending_reply"]["provider_message_id"] == args["provider_message_id"]
  assert {:ok, ^expected_body} = Crypto.decrypt(state_data["pending_reply"]["ciphertext"])
  assert state_data["pending_reply"]["attempt_count"] == 1
  ```

  Then change the request function to return a 200 with one Meta message ID, execute the same job arguments again, and assert the second request body equals `expected_body`, the conversation remains in `main_menu`, and the test process received exactly two transport requests with only one successful response. Do not assert private helper calls or exact SQL; the observable contract is durable reply data, one business transition, and a later transport attempt.

- [ ] **Step 2: Add behavior coverage for duplicate provider/job delivery.**

  Add a test that runs the same inbound job twice after a successful first send. Assert the business state and `last_handled_inbound_message_id` are unchanged, the second execution makes no transport request, and the stored lifecycle is terminal with a `nil` ciphertext:

  ```elixir
  assert state_data["pending_reply"]["status"] == "reply_sent"
  assert is_nil(state_data["pending_reply"]["ciphertext"])
  ```

  Keep the existing Redis/webhook checkpoint behavior in scope by using the same provider message ID and conversation ID; do not add a second dedupe implementation.

- [ ] **Step 3: Add a durable restart-shaped retry test.**

  After the first retryable failure, reload the Conversation from Postgres through the existing read path, discard the original struct, and execute the same Oban arguments. Assert the exact encrypted reply is decrypted from the reloaded `state_data` and sent successfully. The test must not reuse the first `FlowResult` or process-local value as the source of the body.

- [ ] **Step 4: Add side-effect boundary coverage using the existing checkout fixtures.**

  Drive one inbound confirmation through `confirming_order` with the existing `SalesCheckoutFixtures`, Paystack test configuration, and Meta request stub. Make the first reply transport response retryable, then make the retry succeed. Assert counts/identities through the existing durable order, payment-attempt, inventory, and queued delivery queries used by `conversation_state_machine_test.exs`; each logical business record must still be one after the retry. Reuse the repository’s existing idempotency assertions rather than changing checkout or payment code.

  Also retain the existing state-machine tests that prove duplicate confirmation, OTP, inventory, payment, and ticket flows are idempotent. The new worker test only proves that transport retry does not re-enter those flows.

- [ ] **Step 5: Add terminal failure and retry-exhaustion behavior tests.**

  For a permanent Meta 400 or 401 response, assert the worker returns a discard outcome, the business state is unchanged, `needs_human` is `true`, and `handoff_reason` is a stable value such as `"whatsapp_reply_validation_failure"` or `"whatsapp_reply_auth_failure"`; assert the provider’s prose is absent from stored state and logs. Assert `pending_reply.status == "reply_failed"` and `ciphertext` is `nil`.

  For a retryable 500 on a job whose `attempt` equals `max_attempts`, assert the worker marks `reply_failed`, sets `needs_human`, uses exactly `"whatsapp_reply_retry_exhausted"`, clears ciphertext, and returns a discard outcome instead of returning another retryable error. Construct the `Oban.Job` explicitly if `perform_job/2` cannot set the attempt fields, and keep all sensitive values out of its arguments.

- [ ] **Step 6: Extend the job/log safety assertions.**

  Assert `WhatsAppInboundWorker.new/1` and the direct retry job arguments contain no plaintext reply, raw customer inbound body, phone number, WhatsApp ID, access token, payment URL, ticket URL, OTP, or raw provider payload/error. Capture logs around both retryable and terminal failures and assert those same values are absent. Encrypted ciphertext may remain only in durable `Conversation.state_data` while delivery is unresolved; it must not be copied into Oban arguments or logs.

- [ ] **Step 7: Update the Conversation action allowlist as a red test.**

  Add these exact names to `@checkpoint_action_names` in `test/fastcheck/sales/conversation_resource_skeleton_test.exs`:

  ```elixir
  :store_pending_reply,
  :mark_reply_retryable,
  :mark_reply_sent,
  :mark_reply_failed
  ```

  Do not loosen the forbidden-action or sensitive-attribute assertions.

- [ ] **Step 8: Run the new focused test file and confirm it is red for the missing durable lifecycle.**

  Run:

  ```bash
  mix test test/fastcheck/workers/whatsapp_inbound_worker_test.exs test/fastcheck/sales/conversation_resource_skeleton_test.exs
  ```

  Expected result before production changes: failure in the replacement retry test and/or action allowlist because `pending_reply` is not stored and the four named actions do not yet exist. A failure caused only by a malformed test is not acceptable; correct the test until it fails on the missing behavior.

- [ ] **Step 9: Commit the test-only red slice.**

  ```bash
  git add test/fastcheck/workers/whatsapp_inbound_worker_test.exs test/fastcheck/sales/conversation_resource_skeleton_test.exs
  git commit -m "test: reproduce WhatsApp inbound reply retry loss"
  ```

### Task 2: Implement the durable nested reply lifecycle

**Files:**

- Modify: `lib/fastcheck/sales/conversation.ex`
- Modify: `lib/fastcheck/messaging/whatsapp/conversation_state_machine.ex`
- Modify: `lib/fastcheck/workers/whatsapp_inbound_worker.ex`

- [ ] **Step 1: Add four explicit Conversation update actions without changing the business state contract.**

  Add argument-only updates in the `actions` block. They must use `accept([])` and `require_atomic?(false)` like the existing custom changes, and must not expose a generic status setter. Define arguments with stable types:

  ```elixir
  update :store_pending_reply do
    require_atomic?(false)
    accept([])
    argument(:ciphertext, :string, allow_nil?: false)
    argument(:provider_message_id, :string, allow_nil?: false)
    argument(:computed_at, :utc_datetime, allow_nil?: false)
    argument(:correlation_id, :string)
    change(&store_pending_reply_change/2)
  end

  update :mark_reply_retryable do
    require_atomic?(false)
    accept([])
    argument(:provider_message_id, :string, allow_nil?: false)
    argument(:attempted_at, :utc_datetime, allow_nil?: false)
    argument(:failure_class, :string, allow_nil?: false)
    change(&mark_reply_retryable_change/2)
  end

  update :mark_reply_sent do
    require_atomic?(false)
    accept([])
    argument(:provider_message_id, :string, allow_nil?: false)
    argument(:outbound_message_id, :string, allow_nil?: false)
    argument(:sent_at, :utc_datetime, allow_nil?: false)
    change(&mark_reply_sent_change/2)
  end

  update :mark_reply_failed do
    require_atomic?(false)
    accept([])
    argument(:provider_message_id, :string, allow_nil?: false)
    argument(:failed_at, :utc_datetime, allow_nil?: false)
    argument(:failure_class, :string, allow_nil?: false)
    change(&mark_reply_failed_change/2)
  end
  ```

  If Ash’s DSL version requires the argument option block form, use the equivalent existing repository syntax; the actions must still have the exact names, no accepted attributes, and no caller-provided `state_data` map.

- [ ] **Step 2: Implement guarded state-data merge changes.**

  Add private changes in `Conversation` that read the current record using `Changeset.get_data/2`, read action arguments using `Changeset.get_argument/2`, and write only the intended attributes. Merge with the current `state_data` map so keys such as `event_options`, selected offer data, checkout IDs, OTP fields, and unrelated future checkpoint fields cannot be erased.

  The stored shape must use string keys and these statuses only:

  ```elixir
  %{
    "ciphertext" => ciphertext,
    "provider_message_id" => provider_message_id,
    "status" => "reply_pending",
    "attempt_count" => 0,
    "computed_at" => DateTime.to_iso8601(computed_at),
    "last_attempt_at" => nil,
    "failure_class" => nil
  }
  ```

  `store_pending_reply` must also set `state_data["last_handled_inbound_message_id"]` to the same provider ID in that one update. Reject or no-op an existing unresolved reply for another provider ID; make the same provider ID idempotent so a duplicate worker cannot create a second logical reply. Never force or accept a new `state` value in any delivery action.

  `mark_reply_retryable` must require the matching provider ID and a current status of `reply_pending` or `reply_retryable`, preserve ciphertext, set status `reply_retryable`, increment `attempt_count`, set `last_attempt_at` to the supplied timestamp, and record only a stable failure class. `mark_reply_sent` must require the matching provider ID and unresolved status, set status `reply_sent`, increment the attempt count, set the supplied timestamps and outbound provider ID, and set `ciphertext` to `nil`. `mark_reply_failed` must require the matching provider ID and unresolved status, set status `reply_failed`, clear ciphertext, increment the attempt count, record the stable failure class, set `needs_human` to `true`, and set `handoff_reason` to the stable machine-readable failure class.

  Duplicate terminal updates should be harmless when they already describe the same provider reply; stale updates for a different provider ID must return a changeset error and must not overwrite state. Use `Changeset.add_error/3` for guard failures, with safe fixed error atoms/messages only. Do not include reply text, phone numbers, Meta error prose, URLs, tokens, or payloads in errors.

- [ ] **Step 3: Make the state machine encrypt and checkpoint the computed response.**

  In `ConversationStateMachine`, keep the existing business `transition/4` calls and `FlowResult` shape. Change only the final reply checkpoint so `mark_handled/2` for `send_reply?: true` encrypts `result.response_body` with `FastCheck.Crypto.encrypt/1`, then calls `Conversation` action `:store_pending_reply` with the provider message ID, encrypted ciphertext, computation time, and correlation ID. Return the updated Conversation in the `FlowResult`.

  The resulting sequence must be:

  ```elixir
  with {:ok, ciphertext} <- Crypto.encrypt(result.response_body),
       {:ok, conversation} <-
         conversation
         |> Changeset.for_update(
           :store_pending_reply,
           %{ciphertext: ciphertext,
             provider_message_id: command.provider_message_id,
             computed_at: DateTime.utc_now() |> DateTime.truncate(:second),
             correlation_id: command.correlation_id},
           actor: actor
         )
         |> Ash.update(authorize?: false) do
    {:ok, %{result | conversation: conversation}}
  end
  ```

  Preserve the current `send_reply?: false` duplicate/no-reply behavior. A duplicate provider message must return without dispatching business logic and without creating a second pending reply. Do not put plaintext `response_body` into state data, Oban args, telemetry, logs, or error metadata.

- [ ] **Step 4: Split the worker into fresh-inbound and stored-reply paths.**

  Change `perform/1` to pass the complete `Oban.Job` into the flow dispatcher so final-attempt handling can inspect `attempt` and `max_attempts`. At the start of the dispatcher, inspect the loaded Conversation’s `state_data["pending_reply"]`:

  ```elixir
  case unresolved_pending_reply(conversation) do
    {:ok, pending_reply} -> deliver_stored_reply(job, conversation, pending_reply)
    :none -> process_fresh_inbound(job, args, conversation)
  end
  ```

  Keep `ConversationStateMachine` referenced only from `process_fresh_inbound/3`. `deliver_stored_reply/3` may call `Crypto.decrypt/1`, `Client.send_text/3`, and the named Conversation delivery actions, but it must not build a `MessageCommand`, decrypt the inbound message body, or call `ConversationStateMachine.handle_inbound/2`. Deliver only statuses `reply_pending` and `reply_retryable` with non-empty ciphertext; terminal `reply_sent` and `reply_failed` must be treated as already resolved and return `:ok`.

- [ ] **Step 5: Record Meta outcomes with stable failure classes and correct Oban semantics.**

  Use the existing `Client.send_text/3` and its `Response` classification. On success, call `:mark_reply_sent` with the inbound provider ID, Meta’s accepted outbound message ID, and a truncated UTC timestamp, then return `:ok`. If a duplicate/stale worker observes the already-sent terminal state, treat it as success and do not send again when the state proves the logical reply is resolved.

  On a retryable response, classify it as a fixed safe value such as `"whatsapp_reply_transport_failure"`, call `:mark_reply_retryable`, and return `{:error, :whatsapp_send_retryable}` unless this job is at its final allowed attempt. On the final attempt, call `:mark_reply_failed` with exactly `"whatsapp_reply_retry_exhausted"` and return a discard tuple. On non-retryable responses, map only known safe classes:

  ```elixir
  defp permanent_failure_class(%{status: :auth_error}), do: "whatsapp_reply_auth_failure"
  defp permanent_failure_class(%{status: :validation_error}), do: "whatsapp_reply_validation_failure"
  defp permanent_failure_class(_response), do: "whatsapp_reply_failed"
  ```

  Record that class with `:mark_reply_failed` and return a discard tuple. Never use `provider_error_message`, raw response inspection, or provider payload data as `handoff_reason`, job arguments, log metadata, or telemetry metadata. Do not retry a failed decrypt as a Meta transport retry; return a safe fixed error for corrupt ciphertext and make it operator-visible through the permanent failure action if the stored reply cannot be delivered.

- [ ] **Step 6: Preserve existing sanitization, telemetry, and Redis/Oban boundaries.**

  Keep `sanitize_args/1` removing raw inbound body, phone, and WhatsApp ID. Do not add reply text, ciphertext, phone values, access tokens, payment URLs, ticket URLs, OTPs, or raw provider responses to job arguments. Keep logs and telemetry limited to the existing `Correlation.operational_metadata/1` and redacted provider hash/status fields. Do not add a Redis pending-reply key or a new cache. Existing inbound Redis claim/release and Oban uniqueness stay unchanged.

- [ ] **Step 7: Run the focused regression suite and fix only implementation failures.**

  Run:

  ```bash
  mix test test/fastcheck/workers/whatsapp_inbound_worker_test.exs test/fastcheck/sales/conversation_resource_skeleton_test.exs
  mix test test/fastcheck/messaging/whatsapp/conversation_state_machine_test.exs
  ```

  Expected result: all updated worker/resource/state-machine tests pass, including the first failed send, reloaded stored reply, duplicate execution, terminal failure, and final-attempt exhaustion. If an unrelated test fails, isolate whether the changed files caused it before editing anything outside this plan.

- [ ] **Step 8: Commit the production implementation.**

  ```bash
  git add lib/fastcheck/sales/conversation.ex lib/fastcheck/messaging/whatsapp/conversation_state_machine.ex lib/fastcheck/workers/whatsapp_inbound_worker.ex
  git commit -m "fix: make WhatsApp inbound replies retry safe"
  ```

### Task 3: Verify the complete narrow change and hand off

**Files:**

- No additional production files; only fix the three implementation files or two test files above if verification exposes a defect in this change.

- [ ] **Step 1: Run formatting and every required focused test command.**

  Run each command separately and retain the result:

  ```bash
  mix format --check-formatted
  mix test test/fastcheck/workers/whatsapp_inbound_worker_test.exs
  mix test test/fastcheck/messaging/whatsapp/conversation_state_machine_test.exs
  mix test test/fastcheck/messaging/whatsapp/
  mix test test/fastcheck/workers/send_whatsapp_payment_link_worker_test.exs
  mix test test/fastcheck/workers/send_whatsapp_ticket_link_worker_test.exs
  ```

- [ ] **Step 2: Run the repository-standard full gate.**

  Run `mix precommit`. This is required by `AGENTS.md` and covers dependency checks, warnings-as-errors compilation, formatting, Credo strict checks, database setup/migrations through the test alias, and the full test suite. Do not claim completion while this gate has an unresolved failure.

- [ ] **Step 3: Inspect the final diff and safety properties.**

  Run:

  ```bash
  git diff --check main...HEAD
  git diff --stat main...HEAD
  git diff -- lib/fastcheck/sales/conversation.ex lib/fastcheck/messaging/whatsapp/conversation_state_machine.ex lib/fastcheck/workers/whatsapp_inbound_worker.ex test/fastcheck/workers/whatsapp_inbound_worker_test.exs test/fastcheck/sales/conversation_resource_skeleton_test.exs
  ```

  Confirm the only functional change is durable nested reply delivery, `Conversation.state` values and business actions are untouched, no migration or Android file appears, ciphertext is cleared on both terminal outcomes, unrelated state-data keys are merged, and the isolated worktree contains no accidental files.

- [ ] **Step 4: Close the claimed Beads item only after verification.**

  From the authoritative repository workflow, run:

  ```bash
  bd close FastCheckin-v6qp --reason "Done"
  ```

  Do not close `FastCheckin-x43u` and do not create a duplicate work item.

- [ ] **Step 5: Create the narrow pull request with explicit transport semantics.**

  Push `fix/whatsapp-inbound-reply-delivery` and create one PR for `FastCheckin-v6qp`. The description must state:

  ```text
  Root cause: the inbound checkpoint was durable before Meta delivery, so an Oban retry saw the provider ID as duplicate and suppressed the reply.

  Fix: the state machine encrypts and checkpoints the computed reply in Conversation.state_data; retries deliver that stored reply through a worker branch that cannot call the state machine. Named actions record retryable, sent, and permanent outcomes, with retry exhaustion becoming operator-visible.

  Safety: business processing remains exactly once; transport is at least once because a Meta timeout may have been accepted; this PR does not claim mathematically exactly-once provider delivery.

  Scope: no changes to Paystack, checkout, inventory, ticket issuance, scanner, Android, Redis authority, payment-link policy, or Meta configuration.
  ```

  Include the verification commands and their results in the PR body.

