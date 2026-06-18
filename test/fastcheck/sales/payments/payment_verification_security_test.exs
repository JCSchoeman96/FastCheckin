defmodule FastCheck.Sales.Payments.PaymentVerificationSecurityTest do
  use FastCheck.DataCase, async: true

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  @event_id 909

  setup do
    order_id = insert_order_for_event!(@event_id)

    {:ok, attempt} =
      PaymentAttempt
      |> Changeset.for_create(
        :create_initializing,
        %{
          sales_order_id: order_id,
          provider: "paystack",
          provider_reference: "FC-SEC-1",
          idempotency_key: "paystack:init:#{order_id}:sec",
          amount_cents: 10_000,
          currency: "ZAR"
        },
        actor: Fixtures.system_actor()
      )
      |> Ash.create(authorize?: false)

    attempt =
      attempt
      |> Changeset.for_update(
        :mark_initialized,
        %{
          authorization_url: "https://checkout.paystack.com/x",
          access_code: "AC",
          raw_initialize_response: %{"reference" => "FC-SEC-1"},
          initialized_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        actor: Fixtures.system_actor()
      )
      |> Ash.update!(authorize?: false)

    attempt =
      attempt
      |> Changeset.for_update(:mark_verification_started, %{}, actor: Fixtures.system_actor())
      |> Ash.update!(authorize?: false)

    attempt =
      attempt
      |> Changeset.for_update(
        :mark_verified_success,
        %{
          provider_status: "success",
          verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
          last_verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
          raw_verify_response: %{"reference" => "FC-SEC-1", "status" => "success"}
        },
        actor: Fixtures.system_actor()
      )
      |> Ash.update!(authorize?: false)

    {:ok, attempt: attempt}
  end

  test "operator and admin cannot read raw_verify_response", %{attempt: attempt} do
    for actor <- [admin_actor(), operator_actor()] do
      assert [loaded] =
               PaymentAttempt
               |> Query.for_read(:get_by_id, %{id: attempt.id})
               |> Ash.Query.select([:id, :status, :raw_verify_response])
               |> Ash.read!(actor: actor, authorize?: true)

      assert loaded.status == "verified_success"
      assert %Ash.ForbiddenField{} = loaded.raw_verify_response
    end
  end

  test "customer_session cannot verify payment attempts" do
    order_id = insert_order_for_event!(@event_id)

    {:ok, attempt} =
      PaymentAttempt
      |> Changeset.for_create(
        :create_initializing,
        %{
          sales_order_id: order_id,
          provider: "paystack",
          provider_reference: "FC-SEC-CUST",
          idempotency_key: "paystack:init:#{order_id}:cust",
          amount_cents: 10_000,
          currency: "ZAR"
        },
        actor: Fixtures.system_actor()
      )
      |> Ash.create(authorize?: false)

    {:ok, attempt} =
      attempt
      |> Changeset.for_update(
        :mark_initialized,
        %{
          authorization_url: "https://checkout.paystack.com/x",
          access_code: "AC",
          raw_initialize_response: %{"reference" => "FC-SEC-CUST"},
          initialized_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        actor: Fixtures.system_actor()
      )
      |> Ash.update(authorize?: false)

    assert {:error, %Ash.Error.Forbidden{}} =
             attempt
             |> Changeset.for_update(:mark_verification_started, %{},
               actor: customer_session_actor()
             )
             |> Ash.update(authorize?: true)
  end

  defp admin_actor do
    %{actor_type: :admin, actor_id: "admin-1", allowed_event_ids: [@event_id]}
  end

  defp operator_actor do
    %{actor_type: :operator, actor_id: "operator-1", allowed_event_ids: [@event_id]}
  end

  defp customer_session_actor do
    %{actor_type: :customer_session, actor_id: "cust-1", allowed_event_ids: [@event_id]}
  end

  defp insert_order_for_event!(event_id) do
    {:ok, order} =
      FastCheck.Sales.Order
      |> Changeset.for_create(
        :create_draft,
        %{
          public_reference: "ORD-SEC-#{System.unique_integer([:positive])}",
          event_id: event_id,
          source_channel: "test",
          total_amount_cents: 10_000,
          currency: "ZAR",
          idempotency_key: "ord-sec-#{System.unique_integer([:positive])}"
        },
        actor: Fixtures.system_actor()
      )
      |> Ash.create(authorize?: false)

    order =
      order
      |> Changeset.for_update(:mark_awaiting_payment, %{}, actor: Fixtures.system_actor())
      |> Ash.update!(authorize?: false)

    order.id
  end
end
