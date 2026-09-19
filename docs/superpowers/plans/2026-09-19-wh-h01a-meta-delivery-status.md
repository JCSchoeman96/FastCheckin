# WH-H01A Meta delivery-status reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (\`- [ ]\`) syntax for tracking.

**Goal:** Convert signed, H03-scoped Meta WhatsApp delivery callbacks into immutable evidence and a monotonic \`DeliveryAttempt\` projection without replaying Sales business logic.

**Architecture:** Normalize status payloads into a bounded \`ProviderStatus\` value object. Reconcile each event in one Postgres transaction that locks the exact indexed WAMID row, inserts append-only evidence, and invokes named Ash lifecycle actions for projection changes. Keep status processing beside, not inside, the existing inbound message pipeline.

**Tech Stack:** Phoenix controller, Elixir, Ecto/PostgreSQL, Ash resources, ExUnit, local Redis only for existing inbound-message tests.

---

### Task 1: Add bounded Meta status normalization

**Files:**
- Create: \`lib/fastcheck/messaging/whatsapp/provider_status.ex\`
- Create: \`test/fastcheck/messaging/whatsapp/provider_status_test.exs\`

- [ ] **Step 1: Write the failing tests**

Add tests for the public \`ProviderStatus.normalize/2\` contract:

\`\`\`elixir
test "normalizes supported statuses and keeps only bounded fields" do
  payload = status_payload(%{
    "id" => "wamid.tracked",
    "status" => "failed",
    "timestamp" => "1782477600",
    "recipient_id" => "27821234567",
    "errors" => [%{"code" => 131_026, "title" => "private detail"}]
  })

  assert {:ok, [%ProviderStatus{} = event]} =
           ProviderStatus.normalize(payload,
             raw_payload_hash: "payload-hash",
             correlation_id: "corr-123"
           )

  assert event.provider == "meta"
  assert event.provider_message_id == "wamid.tracked"
  assert event.status == "failed"
  assert event.provider_error_code == "131026"
  assert event.raw_payload_hash == "payload-hash"
  assert event.correlation_id == "corr-123"
  assert event.provider_timestamp == DateTime.from_unix!(1_782_477_600)
  refute inspect(event) =~ "27821234567"
  refute inspect(event) =~ "private detail"
end

test "ignores unsupported statuses, malformed timestamps, and oversized WAMIDs" do
  payload = status_payload([
    %{"id" => "bad", "status" => "sent", "timestamp" => "not-a-time"},
    %{"id" => String.duplicate("w", 257), "status" => "sent", "timestamp" => "1782477600"},
    %{"id" => "unknown", "status" => "queued", "timestamp" => "1782477600"}
  ])

  assert {:ok, []} = ProviderStatus.normalize(payload)
end

test "replaces unsafe correlation values with an opaque generated id" do
  assert {:ok, [%ProviderStatus{correlation_id: correlation_id}]} =
           ProviderStatus.normalize(status_payload(%{
             "id" => "wamid.correlation",
             "status" => "sent",
             "timestamp" => "1782477600"
           }), correlation_id: "+27821234567")

  assert correlation_id != "+27821234567"
  assert correlation_id =~ ~r/\A[A-Za-z0-9_-]+\z/
end
\`\`\`

Use a private \`status_payload/1\` helper that accepts either one status map or a list and places it under \`entry[].changes[].value.statuses\`.

- [ ] **Step 2: Run the focused tests and verify they fail for the missing module**

Run:

\`\`\`bash
mix test test/fastcheck/messaging/whatsapp/provider_status_test.exs
\`\`\`

Expected result: compilation fails because \`FastCheck.Messaging.WhatsApp.ProviderStatus\` does not exist.

- [ ] **Step 3: Implement the bounded value object**

Create a struct with the seven fields above. Implement \`normalize/2\` with these constants and rules:

\`\`\`elixir
@statuses ~w(sent delivered read failed deleted)
@max_provider_message_id_length 256
@max_error_code_length 64
@max_correlation_id_length 128
\`\`\`

Traverse only \`entry[].changes[].value.statuses\`. Require a non-empty string WAMID within the limit, a supported status, and a positive Unix timestamp. Convert timestamp strings with \`Integer.parse/1\`, reject trailing characters, and truncate \`DateTime\` to seconds. Accept integer or string error codes only when they become a safe ASCII token. Use \`Correlation.ensure_correlation_id/1\` after validating the request correlation ID. Add \`safe_summary/1\` and an \`Inspect\` implementation that includes a SHA-256 prefix for the WAMID and excludes recipient data and raw payloads.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run:

\`\`\`bash
mix test test/fastcheck/messaging/whatsapp/provider_status_test.exs
\`\`\`

Expected result: all ProviderStatus tests pass with no raw recipient or error detail in inspection output.

- [ ] **Step 5: Commit**

\`\`\`bash
git add lib/fastcheck/messaging/whatsapp/provider_status.ex test/fastcheck/messaging/whatsapp/provider_status_test.exs
git commit -m "feat: normalize Meta delivery status evidence"
\`\`\`

### Task 2: Add the provider-failure lifecycle boundary

**Files:**
- Modify: \`lib/fastcheck/sales/delivery_attempt.ex\`
- Modify: \`test/fastcheck/sales/delivery_attempt_test.exs\`
- Modify: \`test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs\`

- [ ] **Step 1: Write failing lifecycle tests**

Add a test that a provider-accepted attempt can become provider-failed without using local \`mark_failed\`:

\`\`\`elixir
test "Meta provider failure uses a separate lifecycle action" do
  {:ok, accepted} = provider_accepted_attempt!("wamid.provider-failed")

  assert {:ok, failed} =
           update_attempt(accepted, :mark_provider_failed, %{
             provider_error_code: "131026",
             failed_at: ~U[2026-07-05 10:30:00Z]
           })

  assert failed.status == "failed"
  assert failed.provider_status == "failed"
  assert failed.provider_status_at == ~U[2026-07-05 10:30:00Z]
  assert failed.failed_at == ~U[2026-07-05 10:30:00Z]
  assert failed.failure_reason == "provider_status_failed"
  assert failed.provider_error_code == "131026"
end
\`\`\`

Add a test that \`mark_provider_failed\` rejects a delivered record, and extend the manual-review test to cover a \`read\` record if it is not already allowed. Update the skeleton action list to include \`:mark_provider_failed\` in the approved update actions.

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

\`\`\`bash
mix test test/fastcheck/sales/delivery_attempt_test.exs test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs
\`\`\`

Expected result: the new action is missing and the test fails before any production change.

- [ ] **Step 3: Implement the named Ash actions**

Add \`update :mark_provider_failed\` to \`DeliveryAttempt\` with \`require_atomic?(false)\`, accepting \`:provider_error_code\` and \`:failed_at\`, validating a Meta WhatsApp provider message ID, transitioning only from \`provider_accepted\` or \`sent\`, setting \`status\`, \`provider_status\`, \`provider_status_at\`, \`failed_at\`, and \`failure_reason\`, and applying \`optimistic_lock(:lock_version)\`. Keep \`mark_failed\` unchanged for local transport/application failures. Permit \`read\` as an allowed source for \`mark_manual_review\`, and accept \`:provider_status\` and \`:provider_status_at\` there so conflict projection records the incoming evidence through Ash.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run the same focused command. Expected result: all lifecycle and action-surface tests pass, including stale optimistic-lock tests.

- [ ] **Step 5: Commit**

\`\`\`bash
git add lib/fastcheck/sales/delivery_attempt.ex test/fastcheck/sales/delivery_attempt_test.exs test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs
git commit -m "feat: separate Meta provider failure lifecycle"
\`\`\`

### Task 3: Build the transactional status reconciler

**Files:**
- Create: \`lib/fastcheck/messaging/whatsapp/delivery_status_reconciler.ex\`
- Create: \`test/fastcheck/messaging/whatsapp/delivery_status_reconciler_test.exs\`

- [ ] **Step 1: Write failing integration tests**

Use \`FastCheck.DataCase\` and direct fixture inserts for \`sales_orders\` and \`sales_delivery_attempts\`. Add tests for:

\`\`\`elixir
test "status callbacks project through sent, delivered, and read" do
  attempt_id = insert_attempt!(status: "provider_accepted", provider_status: "accepted", provider_message_id: "wamid.lifecycle")

  assert {:updated, "sent"} = reconcile(event("wamid.lifecycle", "sent", 1))
  assert {:updated, "delivered"} = reconcile(event("wamid.lifecycle", "delivered", 2))
  assert {:updated, "read"} = reconcile(event("wamid.lifecycle", "read", 3))

  assert snapshot_attempt!(attempt_id).status == "read"
  assert evidence_count(attempt_id) == 3
end

test "provider failure is recorded without using local failure semantics" do
  attempt_id = insert_attempt!(status: "provider_accepted", provider_status: "accepted", provider_message_id: "wamid.failed")

  assert {:updated, "failed"} = reconcile(event("wamid.failed", "failed", 4, "131026"))

  assert %{status: "failed", provider_status: "failed", failure_reason: "provider_status_failed"} = snapshot_attempt!(attempt_id)
end

test "duplicate exact evidence is idempotent" do
  attempt_id = insert_attempt!(provider_message_id: "wamid.duplicate")
  event = event("wamid.duplicate", "delivered", 5)

  assert {:updated, "delivered"} = reconcile(event)
  assert {:duplicate, "delivered"} = reconcile(event)
  assert evidence_count(attempt_id) == 1
end

test "unknown WAMIDs do not create evidence or attempts" do
  assert {:ignored, :unknown_wamid} = reconcile(event("wamid.unknown", "read", 6))
  assert Repo.aggregate("sales_delivery_status_events", :count, :id) == 0
end
\`\`\`

Also add tests for older sent after delivered, older delivered after read, failed then later delivered, delivered/read then later failed, deleted observation, raw payload hash persistence, ambiguous WAMID rollback, and order/ticket authority isolation. The contradiction tests must assert two evidence rows remain after manual review.

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

\`\`\`bash
mix test test/fastcheck/messaging/whatsapp/delivery_status_reconciler_test.exs
\`\`\`

Expected result: compilation fails because the reconciler module is missing.

- [ ] **Step 3: Implement the transaction and transition classifier**

Implement \`reconcile/1\` for Meta events and return tagged results for updates, duplicates, ignored events, conflicts, and errors. Inside \`Repo.transaction/1\`:

1. Query \`sales_delivery_attempts\` by the three exact indexed columns and \`FOR UPDATE\`, selecting the fields needed for classification and the attempt ID.
2. Return \`{:ignored, :unknown_wamid}\` for no rows. Roll back with \`:ambiguous_provider_message_id\` for multiple rows.
3. Insert one row into \`sales_delivery_status_events\` with \`raw_payload_hash\` and the unique identity, using \`on_conflict: :nothing\`.
4. Return \`{:duplicate, status}\` for a conflict without projection work.
5. Reload the Ash \`DeliveryAttempt\` by ID inside the same transaction, classify the event, and invoke \`mark_sent\`, \`mark_delivered\`, \`mark_read\`, \`mark_provider_failed\`, or \`mark_manual_review\` through \`Ash.Changeset.for_update/3\` and \`Ash.update/2\`. Use \`system\` actor metadata and call \`Repo.rollback/1\` if the Ash action fails, so evidence and projection commit together.

Use ranks \`sent = 1\`, \`delivered = 2\`, \`read = 3\`. Lower ranks, equal ranks, and older timestamps return out-of-order without projection changes. A later success after failed and a later failed event after delivered/read return manual-review. \`deleted\` inserts evidence and leaves the projection unchanged. Never call \`Repo.update_all\` on \`sales_delivery_attempts\`.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run:

\`\`\`bash
mix test test/fastcheck/messaging/whatsapp/delivery_status_reconciler_test.exs
\`\`\`

Expected result: all reconciler tests pass, including evidence hash, duplicate, out-of-order, contradiction, and isolation assertions.

- [ ] **Step 5: Commit**

\`\`\`bash
git add lib/fastcheck/messaging/whatsapp/delivery_status_reconciler.ex test/fastcheck/messaging/whatsapp/delivery_status_reconciler_test.exs
git commit -m "feat: reconcile Meta delivery status evidence transactionally"
\`\`\`

### Task 4: Integrate status reconciliation into the scoped webhook

**Files:**
- Modify: \`lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex\`
- Modify: \`test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs\`
- Modify: \`test/support/whatsapp_webhook_test_support.ex\`

- [ ] **Step 1: Write failing controller tests**

Extend \`status_body/1\` to accept a WAMID, status, timestamp, optional error code, WABA, and phone ID. Add signed controller tests that seed a provider-accepted attempt and assert:

\`\`\`elixir
test "signed scoped status callback reconciles without inbound side effects", %{conn: conn} do
  attempt_id = insert_provider_accepted_attempt!("wamid.controller-status")
  body = WebhookTestSupport.status_body(provider_message_id: "wamid.controller-status", status: "delivered")

  conn =
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-hub-signature-256", WebhookTestSupport.sign_body(body))
    |> post(@webhook_path, body)

  assert response(conn, 200) == ""
  assert snapshot_attempt!(attempt_id).status == "delivered"
  assert evidence_count(attempt_id) == 1
  assert count_conversations() == 0
  refute_enqueued(worker: WhatsAppInboundWorker)
end
\`\`\`

Add tests proving wrong WABA, wrong phone, and invalid signatures leave evidence and projection unchanged. Add a mixed payload test that combines one matching status change and one matching text message and asserts both evidence and the inbound worker job exist.

- [ ] **Step 2: Run the focused controller tests and verify the new tests fail**

Run:

\`\`\`bash
mix test test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs
\`\`\`

Expected result: status callbacks remain no-ops because the controller does not yet normalize or reconcile them.

- [ ] **Step 3: Wire the existing verified and scoped path**

After \`WebhookScope.filter/2\`, compute the raw body hash, normalize statuses, and process them before \`InboundNormalizer.normalize/2\`. Continue to the message pipeline after every non-error status result. Log only safe status summaries and hashed WAMIDs. Map reconciliation errors to the existing 503 response. Keep scope ignores at 200 and signature/config failures unchanged.

- [ ] **Step 4: Run the focused controller tests and verify they pass**

Run:

\`\`\`bash
mix test test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs
\`\`\`

Expected result: all controller tests pass, including invalid signature, scope filtering, mixed payload, and side-effect isolation checks.

- [ ] **Step 5: Commit**

\`\`\`bash
git add lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs test/support/whatsapp_webhook_test_support.ex
git commit -m "feat: route scoped Meta statuses to reconciliation"
\`\`\`

### Task 5: Refactor, verify, and prepare the handoff

**Files:**
- Modify only files identified by failing tests or formatter output.

- [ ] **Step 1: Run focused status tests together**

\`\`\`bash
mix test test/fastcheck/messaging/whatsapp/provider_status_test.exs test/fastcheck/messaging/whatsapp/delivery_status_reconciler_test.exs test/fastcheck/sales/delivery_attempt_test.exs test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs
\`\`\`

- [ ] **Step 2: Run formatting and static checks**

\`\`\`bash
mix format
mix credo --strict
\`\`\`

Review the diff for raw \`Repo.update_all\` against \`sales_delivery_attempts\`, raw WAMID logging, and any status path that calls business logic.

- [ ] **Step 3: Run the project verification gate**

\`\`\`bash
mix precommit
\`\`\`

Expected result: dependency checks, compile with warnings as errors, formatting, Credo, and the full test suite pass. If a failure is unrelated to H01A, record the exact command and error rather than broadening scope.

- [ ] **Step 4: Commit any final formatting or test-only fixes**

\`\`\`bash
git add lib test docs/superpowers
git commit -m "test: finish WH-H01A verification coverage"
\`\`\`

- [ ] **Step 5: Request independent review**

Provide the reviewer the base SHA \`6c4c912a0bedda2f27a92aa83de072231576bcbc\`, the final branch SHA, this plan, and the H01A requirements. Fix all critical and important findings, rerun the affected tests, and record any rejected minor finding with its technical reason.

- [ ] **Step 6: Verify the final branch state before publication**

\`\`\`bash
git status --short --branch
git diff --check 6c4c912a0bedda2f27a92aa83de072231576bcbc...HEAD
mix precommit
\`\`\`

Only after these commands succeed should the branch be pushed and a pull request opened. Close Beads issue \`FastCheckin-o6a9\` only after review and verification are complete.
