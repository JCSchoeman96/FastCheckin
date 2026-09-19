defmodule FastCheck.Messaging.WhatsApp.DeliveryStatusReconcilerTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias FastCheck.Messaging.WhatsApp.DeliveryStatusReconciler
  alias FastCheck.Messaging.WhatsApp.ProviderStatus
  alias FastCheck.Repo

  @base_timestamp 1_782_477_600

  test "status callbacks project through sent, delivered, and read" do
    attempt_id =
      insert_attempt!(
        status: "provider_accepted",
        provider_status: "accepted",
        provider_message_id: "wamid.lifecycle"
      )

    assert {:updated, "sent"} = reconcile(event("wamid.lifecycle", "sent", 1))
    assert {:updated, "delivered"} = reconcile(event("wamid.lifecycle", "delivered", 2))
    assert {:updated, "read"} = reconcile(event("wamid.lifecycle", "read", 3))

    assert snapshot_attempt!(attempt_id).status == "read"
    assert snapshot_attempt!(attempt_id).provider_status == "read"
    assert evidence_count(attempt_id) == 3
  end

  test "provider success callbacks may skip intermediate states" do
    delivered_id =
      insert_attempt!(
        status: "provider_accepted",
        provider_status: "accepted",
        provider_message_id: "wamid.skip-delivered"
      )

    assert {:updated, "delivered"} =
             reconcile(event("wamid.skip-delivered", "delivered", 4))

    assert snapshot_attempt!(delivered_id).status == "delivered"

    read_id =
      insert_attempt!(
        status: "provider_accepted",
        provider_status: "accepted",
        provider_message_id: "wamid.skip-read"
      )

    assert {:updated, "read"} = reconcile(event("wamid.skip-read", "read", 5))
    assert snapshot_attempt!(read_id).status == "read"
  end

  test "provider failure is recorded without using local failure semantics" do
    attempt_id =
      insert_attempt!(
        status: "provider_accepted",
        provider_status: "accepted",
        provider_message_id: "wamid.failed"
      )

    assert {:updated, "failed"} =
             reconcile(event("wamid.failed", "failed", 6, "131026"))

    assert %{
             status: "failed",
             provider_status: "failed",
             provider_error_code: "131026",
             failure_reason: "provider_status_failed",
             failed_at: failed_at
           } = snapshot_attempt!(attempt_id)

    assert failed_at == DateTime.to_naive(timestamp(6))
  end

  test "duplicate exact evidence is idempotent" do
    attempt_id =
      insert_attempt!(
        status: "provider_accepted",
        provider_status: "accepted",
        provider_message_id: "wamid.duplicate"
      )

    event = event("wamid.duplicate", "delivered", 7)

    assert {:updated, "delivered"} = reconcile(event)
    assert {:duplicate, "delivered"} = reconcile(event)
    assert evidence_count(attempt_id) == 1
    assert snapshot_attempt!(attempt_id).status == "delivered"
  end

  test "unknown WAMIDs do not create evidence or attempts" do
    assert {:ignored, :unknown_wamid} =
             reconcile(event("wamid.unknown", "read", 8))

    assert Repo.aggregate("sales_delivery_attempts", :count, :id) == 0
    assert Repo.aggregate("sales_delivery_status_events", :count, :id) == 0
  end

  test "ambiguous WAMIDs fail safely without choosing an attempt" do
    Repo.query!("DROP INDEX sales_delivery_attempts_meta_whatsapp_wamid_uidx")

    first_id =
      insert_attempt!(
        status: "provider_accepted",
        provider_status: "accepted",
        provider_message_id: "wamid.ambiguous"
      )

    second_id =
      insert_attempt!(
        status: "provider_accepted",
        provider_status: "accepted",
        provider_message_id: "wamid.ambiguous"
      )

    assert first_id != second_id

    assert {:error, :ambiguous_provider_message_id} =
             reconcile(event("wamid.ambiguous", "delivered", 8))
  end

  test "older sent evidence cannot regress a newer delivered state" do
    attempt_id =
      insert_attempt!(
        status: "provider_accepted",
        provider_status: "accepted",
        provider_message_id: "wamid.out-of-order-success"
      )

    assert {:updated, "delivered"} =
             reconcile(event("wamid.out-of-order-success", "delivered", 10))

    assert {:ignored, :out_of_order} =
             reconcile(event("wamid.out-of-order-success", "sent", 9))

    assert snapshot_attempt!(attempt_id).status == "delivered"
    assert evidence_count(attempt_id) == 2
  end

  test "older delivered evidence cannot regress a newer read state" do
    attempt_id =
      insert_attempt!(
        status: "provider_accepted",
        provider_status: "accepted",
        provider_message_id: "wamid.out-of-order-read"
      )

    assert {:updated, "read"} =
             reconcile(event("wamid.out-of-order-read", "read", 12))

    assert {:ignored, :out_of_order} =
             reconcile(event("wamid.out-of-order-read", "delivered", 11))

    assert snapshot_attempt!(attempt_id).status == "read"
    assert evidence_count(attempt_id) == 2
  end

  test "later delivered evidence after failed moves the attempt to manual review" do
    attempt_id =
      insert_attempt!(
        status: "provider_accepted",
        provider_status: "accepted",
        provider_message_id: "wamid.failed-then-delivered"
      )

    assert {:updated, "failed"} =
             reconcile(event("wamid.failed-then-delivered", "failed", 13, "131026"))

    assert {:conflict, :manual_review} =
             reconcile(event("wamid.failed-then-delivered", "delivered", 14))

    assert %{
             status: "manual_review",
             provider_status: "delivered",
             provider_status_at: provider_status_at,
             failure_reason: "provider_status_conflict"
           } = snapshot_attempt!(attempt_id)

    assert provider_status_at == DateTime.to_naive(timestamp(14))
    assert evidence_count(attempt_id) == 2
  end

  test "later failure evidence after delivered and read moves to manual review" do
    for {status, offset, wamid} <- [
          {"delivered", 15, "wamid.delivered-then-failed"},
          {"read", 17, "wamid.read-then-failed"}
        ] do
      attempt_id =
        insert_attempt!(
          status: "provider_accepted",
          provider_status: "accepted",
          provider_message_id: wamid
        )

      assert {:updated, ^status} = reconcile(event(wamid, status, offset))

      assert {:conflict, :manual_review} =
               reconcile(event(wamid, "failed", offset + 1, "131026"))

      assert %{status: "manual_review", provider_status: "failed"} =
               snapshot_attempt!(attempt_id)

      assert evidence_count(attempt_id) == 2
    end
  end

  test "local failure is not treated as Meta provider failure" do
    attempt_id =
      insert_attempt!(
        status: "failed",
        provider_status: nil,
        provider_status_at: nil,
        provider_message_id: "wamid.local-failure"
      )

    assert {:conflict, :manual_review} =
             reconcile(event("wamid.local-failure", "delivered", 18))

    assert %{status: "manual_review", provider_status: "delivered"} =
             snapshot_attempt!(attempt_id)

    assert evidence_count(attempt_id) == 1
  end

  test "deleted evidence is observational and leaves the projection unchanged" do
    attempt_id =
      insert_attempt!(
        status: "provider_accepted",
        provider_status: "accepted",
        provider_message_id: "wamid.deleted"
      )

    assert {:ignored, :observational_status} =
             reconcile(event("wamid.deleted", "deleted", 19))

    assert %{status: "provider_accepted", provider_status: "accepted"} =
             snapshot_attempt!(attempt_id)

    assert evidence_count(attempt_id) == 1
  end

  test "persists the raw payload hash on immutable evidence" do
    attempt_id =
      insert_attempt!(
        status: "provider_accepted",
        provider_status: "accepted",
        provider_message_id: "wamid.raw-hash"
      )

    assert {:updated, "sent"} =
             reconcile(%ProviderStatus{
               provider: "meta",
               provider_message_id: "wamid.raw-hash",
               status: "sent",
               provider_timestamp: timestamp(20),
               provider_error_code: nil,
               raw_payload_hash: "raw-payload-hash",
               correlation_id: "corr-raw-hash"
             })

    assert %{
             raw_payload_hash: "raw-payload-hash",
             correlation_id: "corr-raw-hash",
             provider_message_id: "wamid.raw-hash"
           } =
             Repo.one!(
               from event in "sales_delivery_status_events",
                 where: event.delivery_attempt_id == ^attempt_id,
                 select: map(event, [:raw_payload_hash, :correlation_id, :provider_message_id])
             )
  end

  test "delivery reconciliation does not mutate order or ticket authority" do
    order_id =
      insert_order!("authority-isolation", status: "paid_verified")

    attempt_id =
      insert_attempt!(
        order_id: order_id,
        status: "provider_accepted",
        provider_status: "accepted",
        provider_message_id: "wamid.authority-isolation"
      )

    assert {:updated, "delivered"} =
             reconcile(event("wamid.authority-isolation", "delivered", 21))

    assert snapshot_attempt!(attempt_id).status == "delivered"

    assert Repo.one!(
             from order in "sales_orders",
               where: order.id == ^order_id,
               select: order.status
           ) == "paid_verified"

    assert Repo.aggregate("sales_ticket_issues", :count, :id) == 0
  end

  defp reconcile(event), do: DeliveryStatusReconciler.reconcile(event)

  defp event(wamid, status, offset, error_code \\ nil) do
    %ProviderStatus{
      provider: "meta",
      provider_message_id: wamid,
      status: status,
      provider_timestamp: timestamp(offset),
      provider_error_code: error_code,
      raw_payload_hash: "payload-hash",
      correlation_id: "correlation-id"
    }
  end

  defp timestamp(offset), do: DateTime.from_unix!(@base_timestamp + offset)

  defp insert_order!(suffix, opts \\ []) do
    status = Keyword.get(opts, :status, "awaiting_payment")

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, source_channel, status, total_amount_cents, currency,
           inserted_at, updated_at)
        VALUES ($1, 90001, 'whatsapp', $2, 100, 'ZAR', now(), now())
        RETURNING id
        """,
        ["FC-STATUS-#{suffix}-#{System.unique_integer([:positive])}", status]
      )

    id
  end

  defp insert_attempt!(opts) do
    order_id = Keyword.get_lazy(opts, :order_id, fn -> insert_order!("attempt") end)
    status = Keyword.get(opts, :status, "provider_accepted")
    provider_status = Keyword.get(opts, :provider_status, "accepted")
    provider_message_id = Keyword.get(opts, :provider_message_id)
    provider_status_at = Keyword.get(opts, :provider_status_at, timestamp(0))

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_delivery_attempts
          (sales_order_id, ticket_issue_id, channel, provider, status, provider_message_id,
           provider_status, provider_status_at, attempt_number, inserted_at, updated_at)
        VALUES ($1, NULL, 'whatsapp', 'meta', $2, $3, $4, $5, 1, now(), now())
        RETURNING id
        """,
        [order_id, status, provider_message_id, provider_status, provider_status_at]
      )

    id
  end

  defp snapshot_attempt!(id) do
    Repo.one!(
      from attempt in "sales_delivery_attempts",
        where: attempt.id == ^id,
        select:
          map(attempt, [
            :status,
            :provider_status,
            :provider_status_at,
            :provider_error_code,
            :failure_reason,
            :sent_at,
            :delivered_at,
            :read_at,
            :failed_at
          ])
    )
  end

  defp evidence_count(attempt_id) do
    Repo.aggregate(
      from(event in "sales_delivery_status_events",
        where: event.delivery_attempt_id == ^attempt_id
      ),
      :count,
      :id
    )
  end
end
