defmodule FastCheck.Sales.Payments.PaymentPolicyTest do
  use FastCheck.DataCase, async: true

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  @event_id 910

  setup do
    order_id = insert_order_for_event!(@event_id)

    {:ok, attempt} =
      PaymentAttempt
      |> Changeset.for_create(
        :create_initializing,
        %{
          sales_order_id: order_id,
          provider: "paystack",
          provider_reference: "FC-POL-1",
          idempotency_key: "paystack:init:#{order_id}:pol",
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
          raw_initialize_response: %{"reference" => "FC-POL-1"},
          initialized_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        actor: Fixtures.system_actor()
      )
      |> Ash.update!(authorize?: false)

    {:ok, attempt: attempt}
  end

  test "customer_session cannot run payment verification transitions", %{attempt: attempt} do
    actor = %{actor_type: :customer_session, actor_id: "cust-1", allowed_event_ids: [@event_id]}

    assert_raise Ash.Error.Forbidden, fn ->
      attempt
      |> Changeset.for_update(:mark_verification_started, %{}, actor: actor)
      |> Ash.update!(authorize?: true)
    end
  end

  test "operator cannot read raw verify response", %{attempt: attempt} do
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
          raw_verify_response: %{"reference" => "FC-POL-1"}
        },
        actor: Fixtures.system_actor()
      )
      |> Ash.update!(authorize?: false)

    [loaded] =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: attempt.id})
      |> Ash.Query.select([:id, :raw_verify_response])
      |> Ash.read!(
        actor: %{actor_type: :operator, actor_id: "op-1", allowed_event_ids: [@event_id]},
        authorize?: true
      )

    assert %Ash.ForbiddenField{} = loaded.raw_verify_response
  end

  defp insert_order_for_event!(event_id) do
    alias FastCheck.Sales.Order

    Order
    |> Changeset.for_create(
      :create_draft,
      %{
        event_id: event_id,
        source_channel: "internal_pilot",
        idempotency_key: "pol-order-#{System.unique_integer([:positive])}",
        public_reference: "POL-#{System.unique_integer([:positive])}",
        total_amount_cents: 10_000,
        currency: "ZAR"
      },
      actor: Fixtures.system_actor()
    )
    |> Ash.create!(authorize?: false)
    |> Map.fetch!(:id)
  end
end
