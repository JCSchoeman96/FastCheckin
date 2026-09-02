defmodule FastCheck.Messaging.WhatsApp.DeliveryStatusReconcilerTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias FastCheck.Messaging.WhatsApp.DeliveryStatusReconciler
  alias FastCheck.Messaging.WhatsApp.ProviderStatus
  alias FastCheck.Repo

  @base_timestamp 1_782_477_600

  test "provider acceptance remains distinct from customer delivery evidence" do
    order_id = insert_order!("provider-accepted")

    attempt_id =
      insert_attempt!(order_id,
        status: "provider_accepted",
        provider_status: "accepted",
        provider_message_id: "wamid.accepted"
      )

    attempt = snapshot_attempt!(attempt_id)

    assert attempt.status == "provider_accepted"
    assert attempt.provider_status == "accepted"
    assert is_nil(attempt.sent_at)
    assert is_nil(attempt.delivered_at)
    assert is_nil(attempt.read_at)
  end

  test "sent, delivered, and read callbacks advance one tracked attempt" do
    order_id = insert_order!("success-lifecycle")
    attempt_id = insert_attempt!(order_id, provider_message_id: "wamid.lifecycle")

    assert {:updated, "sent"} =
             DeliveryStatusReconciler.reconcile(provider_status("wamid.lifecycle", "sent", 1))

    assert %{status: "sent", provider_status: "sent", sent_at: sent_at} =
             snapshot_attempt!(attempt_id)

    assert sent_at == stored_timestamp(1)

    assert {:updated, "delivered"} =
             DeliveryStatusReconciler.reconcile(
               provider_status("wamid.lifecycle", "delivered", 2)
             )

    assert %{
             status: "delivered",
             delivered_at: delivered_at,
             sent_at: sent_at
           } = snapshot_attempt!(attempt_id)

    assert delivered_at == stored_timestamp(2)
    assert sent_at == stored_timestamp(1)

    assert {:updated, "read"} =
             DeliveryStatusReconciler.reconcile(provider_status("wamid.lifecycle", "read", 3))

    assert %{
             status: "read",
             read_at: read_at,
             failed_at: nil
           } = snapshot_attempt!(attempt_id)

    assert read_at == stored_timestamp(3)
  end

  test "failed provider evidence produces a safe failure state" do
    order_id = insert_order!("failed-lifecycle")
    attempt_id = insert_attempt!(order_id, provider_message_id: "wamid.failed")

    assert {:updated, "failed"} =
             DeliveryStatusReconciler.reconcile(
               provider_status("wamid.failed", "failed", 4, "131026")
             )

    assert %{
             status: "failed",
             provider_status: "failed",
             provider_error_code: "131026",
             failure_reason: "provider_status_failed",
             failed_at: failed_at
           } = snapshot_attempt!(attempt_id)

    assert failed_at == stored_timestamp(4)
  end

  test "duplicate callback is idempotent and does not add another evidence row" do
    order_id = insert_order!("duplicate-callback")
    wamid = "wamid.duplicate-status"
    event = provider_status(wamid, "delivered", 5)
    attempt_id = insert_attempt!(order_id, provider_message_id: wamid)

    assert {:updated, "delivered"} = DeliveryStatusReconciler.reconcile(event)
    assert {:duplicate, "delivered"} = DeliveryStatusReconciler.reconcile(event)
    assert evidence_count(attempt_id) == 1
    assert snapshot_attempt!(attempt_id).status == "delivered"
  end

  test "unknown WAMID is ignored without creating an attempt or evidence" do
    assert {:ignored, :unknown_wamid} =
             DeliveryStatusReconciler.reconcile(
               provider_status("wamid.untracked-reply", "delivered", 6)
             )

    assert Repo.aggregate("sales_delivery_attempts", :count, :id) == 0
    assert Repo.aggregate("sales_delivery_status_events", :count, :id) == 0
  end

  test "older sent evidence cannot regress a newer delivered state" do
    order_id = insert_order!("out-of-order-success")
    wamid = "wamid.out-of-order-success"
    attempt_id = insert_attempt!(order_id, provider_message_id: wamid)

    assert {:updated, "delivered"} =
             DeliveryStatusReconciler.reconcile(provider_status(wamid, "delivered", 8))

    assert {:ignored, :out_of_order} =
             DeliveryStatusReconciler.reconcile(provider_status(wamid, "sent", 7))

    assert %{status: "delivered", delivered_at: delivered_at} = snapshot_attempt!(attempt_id)
    assert delivered_at == stored_timestamp(8)
  end

  test "older failed evidence cannot regress a newer read state" do
    order_id = insert_order!("out-of-order-failure")
    wamid = "wamid.out-of-order-failure"
    attempt_id = insert_attempt!(order_id, provider_message_id: wamid)

    assert {:updated, "read"} =
             DeliveryStatusReconciler.reconcile(provider_status(wamid, "read", 10))

    assert {:ignored, :out_of_order} =
             DeliveryStatusReconciler.reconcile(provider_status(wamid, "failed", 9, "131000"))

    assert %{status: "read", read_at: read_at} = snapshot_attempt!(attempt_id)
    assert read_at == stored_timestamp(10)
  end

  test "older failed evidence cannot regress newer provider acceptance" do
    order_id = insert_order!("out-of-order-accepted-failure")
    wamid = "wamid.out-of-order-accepted-failure"

    attempt_id =
      insert_attempt!(order_id,
        status: "provider_accepted",
        provider_status: "accepted",
        provider_status_at: stored_timestamp(20),
        provider_message_id: wamid
      )

    assert {:ignored, :out_of_order} =
             DeliveryStatusReconciler.reconcile(provider_status(wamid, "failed", 19, "131000"))

    assert %{status: "provider_accepted", provider_status: "accepted"} =
             snapshot_attempt!(attempt_id)

    assert evidence_count(attempt_id) == 1
  end

  test "later contradictory success moves a failed attempt to manual review without retry" do
    order_id = insert_order!("contradictory-status")
    wamid = "wamid.contradictory"
    attempt_id = insert_attempt!(order_id, provider_message_id: wamid)

    assert {:updated, "failed"} =
             DeliveryStatusReconciler.reconcile(provider_status(wamid, "failed", 11, "131026"))

    assert {:conflict, :manual_review} =
             DeliveryStatusReconciler.reconcile(provider_status(wamid, "delivered", 12))

    assert %{
             status: "manual_review",
             failure_reason: "provider_status_conflict",
             fallback_channel: "manual_review",
             delivered_at: delivered_at
           } = snapshot_attempt!(attempt_id)

    assert delivered_at == stored_timestamp(12)
    assert evidence_count(attempt_id) == 2
  end

  test "deleted evidence is observational and does not alter order authority" do
    order_id = insert_order!("deleted-observation", status: "paid_verified")
    wamid = "wamid.deleted"
    attempt_id = insert_attempt!(order_id, provider_message_id: wamid)

    assert {:ignored, :observational_status} =
             DeliveryStatusReconciler.reconcile(provider_status(wamid, "deleted", 13))

    assert snapshot_attempt!(attempt_id).status == "queued"

    assert Repo.one!(from o in "sales_orders", where: o.id == ^order_id, select: o.status) ==
             "paid_verified"

    assert evidence_count(attempt_id) == 1
  end

  test "delivery reconciliation cannot mutate payment or ticket authority" do
    order_id = insert_order!("authority-isolation", status: "paid_verified")
    wamid = "wamid.authority-isolation"
    attempt_id = insert_attempt!(order_id, provider_message_id: wamid)

    assert {:updated, "delivered"} =
             DeliveryStatusReconciler.reconcile(provider_status(wamid, "delivered", 14))

    assert snapshot_attempt!(attempt_id).status == "delivered"

    assert Repo.one!(from o in "sales_orders", where: o.id == ^order_id, select: o.status) ==
             "paid_verified"

    assert Repo.aggregate("sales_ticket_issues", :count, :id) == 0
  end

  defp provider_status(wamid, status, offset, error_code \\ nil) do
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
  defp stored_timestamp(offset), do: timestamp(offset) |> DateTime.to_naive()

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

  defp insert_attempt!(order_id, opts) do
    status = Keyword.get(opts, :status, "queued")
    provider_status = Keyword.get(opts, :provider_status)
    provider_message_id = Keyword.get(opts, :provider_message_id)
    provider_status_at = Keyword.get(opts, :provider_status_at)

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
      from d in "sales_delivery_attempts",
        where: d.id == ^id,
        select:
          map(d, [
            :status,
            :provider_status,
            :provider_error_code,
            :failure_reason,
            :fallback_channel,
            :sent_at,
            :delivered_at,
            :read_at,
            :failed_at
          ])
    )
  end

  defp evidence_count(attempt_id) do
    Repo.aggregate(
      from(e in "sales_delivery_status_events", where: e.delivery_attempt_id == ^attempt_id),
      :count,
      :id
    )
  end
end
