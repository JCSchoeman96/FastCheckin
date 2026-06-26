defmodule FastCheck.Workers.SendWhatsAppPaymentLinkWorkerTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query
  import ExUnit.CaptureLog

  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
  alias FastCheck.Repo
  alias FastCheck.Sales.Payments.TestSupport, as: PaymentSupport
  alias FastCheck.SalesCheckoutFixtures, as: SalesFixtures
  alias FastCheck.Workers.SendWhatsAppPaymentLinkWorker

  setup do
    WebhookTestSupport.flush_redis_keys!()
    whatsapp_cleanup = WebhookTestSupport.setup_whatsapp!()
    paystack_cleanup = PaymentSupport.setup_paystack!()
    offer = SalesFixtures.insert_offer!()

    on_exit(fn ->
      SalesFixtures.flush_inventory_keys(offer.id)
      WebhookTestSupport.flush_redis_keys!()
      whatsapp_cleanup.()
      paystack_cleanup.()
    end)

    {:ok, offer: offer}
  end

  test "sends Paystack link once and records masked DeliveryAttempt", %{offer: offer} do
    test_pid = self()
    {conversation_id, order, attempt} = initialized_payment!(offer)

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.payment-out"}]})
       }}
    end)

    args = %{
      "conversation_id" => conversation_id,
      "sales_order_id" => order.id,
      "payment_attempt_id" => attempt.id
    }

    log =
      capture_log(fn ->
        assert :ok = perform_job(SendWhatsAppPaymentLinkWorker, args)
        assert :ok = perform_job(SendWhatsAppPaymentLinkWorker, args)
      end)

    assert_received {:whatsapp_request, request}
    refute_received {:whatsapp_request, _duplicate}
    assert request.options.json["text"]["body"] =~ attempt.authorization_url

    attempts =
      Repo.all(
        from d in "sales_delivery_attempts",
          where: d.sales_order_id == ^order.id,
          select: map(d, [:ticket_issue_id, :recipient, :status, :provider_message_id])
      )

    assert [
             %{
               ticket_issue_id: nil,
               recipient: recipient,
               status: "sent",
               provider_message_id: "wamid.payment-out"
             }
           ] = attempts

    assert recipient =~ "***"
    refute recipient =~ "+27821234567"
    refute log =~ attempt.authorization_url
    refute log =~ "+27821234567"
  end

  test "marks DeliveryAttempt failed without storing Paystack URL when WhatsApp send fails", %{
    offer: offer
  } do
    {conversation_id, order, attempt} = initialized_payment!(offer)

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      {:ok,
       %Req.Response{
         status: 500,
         body: Jason.encode!(%{"error" => %{"message" => attempt.authorization_url}})
       }}
    end)

    assert {:error, %{retryable?: true}} =
             perform_job(SendWhatsAppPaymentLinkWorker, %{
               "conversation_id" => conversation_id,
               "sales_order_id" => order.id,
               "payment_attempt_id" => attempt.id
             })

    assert [
             %{
               status: "failed",
               provider_error_message: "whatsapp send failed",
               failure_reason: "server_error"
             }
           ] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.sales_order_id == ^order.id,
                 select: map(d, [:status, :provider_error_message, :failure_reason])
             )

    attempt_log =
      Repo.one!(
        from d in "sales_delivery_attempts",
          where: d.sales_order_id == ^order.id,
          select: d.provider_error_message
      )

    refute attempt_log =~ attempt.authorization_url
  end

  defp initialized_payment!(offer) do
    {order, session} =
      PaymentSupport.checkout_ready_for_payment!(offer, %{
        source_channel: "whatsapp",
        buyer_phone: "+27821234567",
        buyer_email: "buyer@example.com"
      })

    %{rows: [[conversation_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, needs_human, inserted_at, updated_at)
        VALUES
          ('+27821234567', '27821234567', 'af', 'payment_pending', $1, false, now(), now())
        RETURNING id
        """,
        [%{"sales_order_id" => order.id, "order_public_reference" => order.public_reference}]
      )

    Application.put_env(:fastcheck, :paystack_request_fun, PaymentSupport.success_request_fun())

    {:ok, result} =
      FastCheck.Sales.Payments.TransactionInitialization.initialize_for_checkout_session(
        session.id,
        SalesFixtures.system_actor()
      )

    attempt =
      FastCheck.Sales.PaymentAttempt
      |> Ash.Query.for_read(:get_by_id, %{id: result.payment_attempt_id})
      |> Ash.read_one!(authorize?: false)

    {conversation_id, order, attempt}
  end
end
