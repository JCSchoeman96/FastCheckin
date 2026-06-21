defmodule FastCheck.Sales.ManualReviewTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query

  alias FastCheck.Repo
  alias FastCheck.Sales.ManualReview
  alias FastCheck.Sales.Payments.VerifyPaymentWorker
  alias FastCheck.Workers.IssueTicketsWorker

  @raw_email "manual.review@example.com"
  @raw_phone "+27123456789"
  @access_code "ACCESS_SECRET"
  @authorization_url "https://checkout.paystack.test/pay/secret"
  @ticket_code "TICKET-SECRET"
  @qr_hash "qr-secret"
  @delivery_hash "delivery-secret"
  @actor %{id: "dashboard-admin", username: "dashboard-admin"}

  test "list_queue returns bounded safe review rows" do
    order_id = insert_review_order!()

    assert %{entries: entries} = ManualReview.list_queue(%{}, limit: 50)
    assert [entry | _] = Enum.filter(entries, &(&1.subject_type == "order"))

    assert entry.subject_id == Integer.to_string(order_id)
    assert entry.order_public_reference
    assert entry.reason_code == "payment_state_conflict"
    assert entry.buyer_email_masked != @raw_email
    assert entry.buyer_phone_masked != @raw_phone
    refute unsafe_value_present?(entry)
  end

  test "list_queue includes manual-review payment attempts and ticket issues" do
    order_id = insert_review_order!(status: "paid_verified")
    attempt_id = insert_payment_attempt!(order_id, "manual_review")
    ticket_issue_id = insert_ticket_issue!(order_id)

    entries = ManualReview.list_queue(%{}, limit: 50).entries

    assert Enum.any?(
             entries,
             &(&1.subject_type == "payment_attempt" and
                 &1.subject_id == Integer.to_string(attempt_id))
           )

    assert Enum.any?(
             entries,
             &(&1.subject_type == "ticket_issue" and
                 &1.subject_id == Integer.to_string(ticket_issue_id))
           )

    refute Enum.any?(
             entries,
             &(&1.subject_type == "order" and &1.subject_id == Integer.to_string(order_id))
           )
  end

  test "get_context returns safe payment and ticket summaries" do
    order_id = insert_review_order!()
    attempt_id = insert_payment_attempt!(order_id, "manual_review")
    ticket_issue_id = insert_ticket_issue!(order_id)

    assert {:ok, payment_context} = ManualReview.get_context("payment_attempt", attempt_id)
    assert payment_context.payment_attempt_id == attempt_id
    assert payment_context.payment_summary.status == "manual_review"
    assert payment_context.payment_summary.provider_reference_masked != "provider-ref"
    refute unsafe_value_present?(payment_context)

    assert {:ok, ticket_context} = ManualReview.get_context("ticket_issue", ticket_issue_id)
    assert ticket_context.ticket_issue_summary.ticket_code_suffix == "***CRET"
    refute unsafe_value_present?(ticket_context)
  end

  test "return_to_fulfillment_queue succeeds when preconditions are safe" do
    order_id = insert_review_order!()
    insert_checkout_session!(order_id, "paid")
    insert_payment_attempt!(order_id, "verified_success")

    assert {:ok, _} =
             ManualReview.return_to_fulfillment_queue(order_id, @actor, %{
               "reason_code" => "return_to_fulfillment_queue",
               "note" => "safe after review"
             })

    assert_order_status(order_id, "fulfillment_queued")
    assert state_transition?("Order", order_id, "manual_review", "fulfillment_queued")
  end

  test "add_note and assignment actions write manual review audit only" do
    order_id = insert_review_order!()

    assert {:ok, _} =
             ManualReview.add_note("order", order_id, @actor, %{
               "reason_code" => "operator_note",
               "note" => "Needs finance review\u0000"
             })

    assert {:ok, _} =
             ManualReview.assign("order", order_id, @actor, %{
               "reason_code" => "operator_assigned"
             })

    actions = review_actions(order_id)
    assert Enum.map(actions, & &1.action) == ["add_note", "assign_to_self"]
    assert hd(actions).note == "Needs finance review"
    assert Enum.all?(actions, &(&1.actor_id == "dashboard-admin"))
  end

  test "payment retry requires reason, audits transition, and enqueues VerifyPaymentWorker" do
    order_id = insert_review_order!()
    attempt_id = insert_payment_attempt!(order_id, "manual_review")

    assert {:error, :reason_required} =
             ManualReview.retry_payment_verification(attempt_id, @actor, %{})

    assert {:ok, _} =
             ManualReview.retry_payment_verification(attempt_id, @actor, %{
               "reason_code" => "retry_payment_verification"
             })

    assert_attempt_status(attempt_id, "verification_retry_queued")
    assert_enqueued(worker: VerifyPaymentWorker, args: %{"payment_attempt_id" => attempt_id})
    assert [%{action: "retry_payment_verification"}] = review_actions(order_id)

    assert state_transition?(
             "PaymentAttempt",
             attempt_id,
             "manual_review",
             "verification_retry_queued"
           )
  end

  test "issuance retry audits transition and enqueues IssueTicketsWorker" do
    order_id = insert_review_order!()
    insert_checkout_session!(order_id, "paid")
    insert_payment_attempt!(order_id, "verified_success")

    assert {:ok, _} =
             ManualReview.retry_ticket_issuance(order_id, @actor, %{
               "reason_code" => "retry_ticket_issuance"
             })

    assert_order_status(order_id, "issuance_retry_queued")
    assert_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order_id})
    assert [%{action: "retry_ticket_issuance"}] = review_actions(order_id)
    assert state_transition?("Order", order_id, "manual_review", "issuance_retry_queued")
  end

  test "return_to_fulfillment_queue fails closed on unsafe or unknown payment state" do
    order_id = insert_review_order!()
    insert_checkout_session!(order_id, "paid")
    insert_payment_attempt!(order_id, "verified_amount_mismatch")

    assert {:error, :unsafe_manual_review_transition} =
             ManualReview.return_to_fulfillment_queue(order_id, @actor, %{
               "reason_code" => "return_to_fulfillment_queue",
               "note" => "safe after review"
             })

    assert_order_status(order_id, "manual_review")
    refute state_transition?("Order", order_id, "manual_review", "fulfillment_queued")
  end

  test "close_no_fulfillment requires bounded note and reason" do
    order_id = insert_review_order!()

    assert {:error, :note_required} =
             ManualReview.close_no_fulfillment(order_id, @actor, %{
               "reason_code" => "close_no_fulfillment"
             })

    assert {:error, :note_too_long} =
             ManualReview.close_no_fulfillment(order_id, @actor, %{
               "reason_code" => "close_no_fulfillment",
               "note" => String.duplicate("a", 1001)
             })

    assert {:ok, _} =
             ManualReview.close_no_fulfillment(order_id, @actor, %{
               "reason_code" => "close_no_fulfillment",
               "note" => "No safe fulfillment path"
             })

    assert_order_status(order_id, "no_fulfillment_closed")
  end

  defp unsafe_value_present?(term) do
    encoded = inspect(term)

    Enum.any?(
      [
        @raw_email,
        @raw_phone,
        @access_code,
        @authorization_url,
        @ticket_code,
        @qr_hash,
        @delivery_hash
      ],
      &String.contains?(encoded, &1)
    )
  end

  defp review_actions(order_id) do
    Repo.all(
      from a in "sales_manual_review_actions",
        where: a.sales_order_id == ^order_id,
        order_by: [asc: a.inserted_at],
        select: %{
          action: a.action,
          actor_id: a.actor_id,
          note: a.note,
          reason_code: a.reason_code
        }
    )
  end

  defp state_transition?(entity_type, entity_id, from_state, to_state) do
    Repo.exists?(
      from st in "sales_state_transitions",
        where:
          st.entity_type == ^entity_type and st.entity_id == ^Integer.to_string(entity_id) and
            st.from_state == ^from_state and st.to_state == ^to_state
    )
  end

  defp assert_order_status(order_id, status) do
    assert Repo.one!(from o in "sales_orders", where: o.id == ^order_id, select: o.status) ==
             status
  end

  defp assert_attempt_status(attempt_id, status) do
    assert Repo.one!(
             from p in "sales_payment_attempts", where: p.id == ^attempt_id, select: p.status
           ) ==
             status
  end

  defp insert_review_order!(opts \\ []) do
    status = Keyword.get(opts, :status, "manual_review")

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, manual_review_reason, lock_version,
           inserted_at, updated_at)
        VALUES
          ($1, 91001, 'Manual Buyer', $2, $3, 'admin', $4, 10000, 'ZAR',
           'payment_state_conflict', 1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        ["MR-#{System.unique_integer([:positive])}", @raw_phone, @raw_email, status]
      )

    id
  end

  defp insert_checkout_session!(order_id, status) do
    Repo.query!(
      """
      INSERT INTO sales_checkout_sessions
        (sales_order_id, status, hold_quantity, state_data, lock_version, inserted_at, updated_at)
      VALUES ($1, $2, 1, '{}', 1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [order_id, status]
    )
  end

  defp insert_payment_attempt!(order_id, status, opts \\ []) do
    reason = Keyword.get(opts, :manual_review_reason)

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_payment_attempts
          (sales_order_id, provider, provider_reference, idempotency_key, authorization_url,
           access_code, status, amount_cents, currency, verification_attempt_count,
           manual_review_reason, raw_initialize_response, raw_verify_response,
           inserted_at, updated_at)
        VALUES
          ($1, 'paystack', $2, $3, $4, $5, $6, 10000, 'ZAR', 1, $7,
           '{"secret":"raw-init"}', '{"secret":"raw-verify"}',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [
          order_id,
          "provider-ref-#{System.unique_integer([:positive])}",
          "idem-secret",
          @authorization_url,
          @access_code,
          status,
          reason
        ]
      )

    id
  end

  defp insert_ticket_issue!(order_id) do
    %{rows: [[line_id]]} =
      Repo.query!("""
      INSERT INTO sales_ticket_offers
        (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
         initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
         lock_version, inserted_at, updated_at)
      VALUES
        (91001, 'Manual Offer', 'General', 10000, 'ZAR', 100, 100, 4, true, 'admin',
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc' + interval '30 days',
         1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      RETURNING id
      """)

    %{rows: [[order_line_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_order_lines
          (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
           event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
           metadata, inserted_at, updated_at)
        VALUES
          ($1, $2, 1, 'General', 'Manual Offer', 'Manual Event', 1, 10000, 10000,
           'ZAR', '{}', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [order_id, line_id]
      )

    %{rows: [[issue_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_ticket_issues
          (sales_order_id, sales_order_line_id, line_item_sequence, attendee_id, ticket_code,
           qr_token_hash, delivery_token_hash, status, scanner_status, inserted_at, updated_at)
        VALUES
          ($1, $2, 1, 123456, $3, $4, $5, 'manual_review', 'valid',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [order_id, order_line_id, @ticket_code, @qr_hash, @delivery_hash]
      )

    issue_id
  end
end
