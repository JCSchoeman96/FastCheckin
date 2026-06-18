defmodule FastCheck.Payments.Paystack.WebhookSecurityTest do
  use FastCheck.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ash.Query
  alias FastCheck.Sales.PaymentEvent
  alias FastCheck.Sales.Payments.TestSupport, as: PaystackSupport
  alias FastCheck.Sales.Payments.WebhookIngestion
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    PaystackSupport.setup_paystack!()
    PaystackSupport.flush_webhook_dedupe_keys!()
    on_exit(fn -> PaystackSupport.flush_webhook_dedupe_keys!() end)
    :ok
  end

  test "operator cannot read raw_payload" do
    insert_payment_event!()

    assert [event] =
             PaymentEvent
             |> Query.new()
             |> Ash.read!(actor: operator_actor(), authorize?: true)

    assert %Ash.ForbiddenField{} = event.raw_payload
    assert is_binary(event.event_type)
  end

  test "admin can read summarized fields but not raw_payload" do
    insert_payment_event!()

    assert [event] =
             PaymentEvent
             |> Query.new()
             |> Ash.read!(actor: admin_actor(), authorize?: true)

    assert %Ash.ForbiddenField{} = event.raw_payload
    assert event.event_type == "charge.success"
    assert event.processing_status == "stored"
  end

  test "customer_session cannot read payment events" do
    insert_payment_event!()

    assert {:error, %Ash.Error.Forbidden{}} =
             PaymentEvent
             |> Query.new()
             |> Ash.read(actor: customer_session_actor(), authorize?: true)
  end

  test "ingest logs do not include signature or raw body" do
    event_id = "evt-log-#{System.unique_integer([:positive])}"
    body = PaystackSupport.charge_success_webhook_body(provider_event_id: event_id)
    signature = PaystackSupport.sign_webhook_body(body)

    log =
      capture_log(fn ->
        assert {:ok, :created, _} =
                 WebhookIngestion.ingest(body, %{"x-paystack-signature" => signature})
      end)

    refute log =~ signature
    refute log =~ body
    refute log =~ "buyer"
  end

  defp insert_payment_event! do
    FastCheck.Repo.query!("""
    INSERT INTO sales_payment_events
      (provider, provider_event_id, provider_reference, event_type, payload_hash,
       raw_payload, processing_status, processing_attempt_count, inserted_at, updated_at)
    VALUES
      ('paystack', 'evt-policy-1', 'ref-policy-1', 'charge.success', 'hash-policy-1',
       '{"event":"charge.success"}', 'stored', 0, now(), now())
    """)
  end

  defp admin_actor, do: Fixtures.admin_actor([101])
  defp operator_actor, do: Fixtures.operator_actor([101])

  defp customer_session_actor, do: Fixtures.customer_session_actor([101])
end
