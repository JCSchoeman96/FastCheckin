defmodule FastCheck.Sales.PaymentAttemptInitializationActionsTest do
  use FastCheck.DataCase, async: true

  require Ash.Query

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.StateTransition
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  test "create_initializing and mark_initialized append state transitions" do
    order_id = insert_order!()

    context = %{
      actor: Fixtures.system_actor(),
      correlation_id: "corr-actions-1",
      transition_metadata: %{source_channel: "test"}
    }

    assert {:ok, attempt} =
             PaymentAttempt
             |> Changeset.for_create(
               :create_initializing,
               %{
                 sales_order_id: order_id,
                 provider: "paystack",
                 provider_reference: "FC-ACTIONS-1",
                 idempotency_key: "paystack:init:#{order_id}:1",
                 amount_cents: 10_000,
                 currency: "ZAR"
               },
               actor: context.actor
             )
             |> Ash.create(authorize?: false, context: context)

    assert attempt.status == "initializing"

    assert {:ok, initialized} =
             attempt
             |> Changeset.for_update(
               :mark_initialized,
               %{
                 authorization_url: "https://checkout.paystack.com/x",
                 access_code: "AC",
                 raw_initialize_response: %{"reference" => "FC-ACTIONS-1"},
                 initialized_at: DateTime.utc_now() |> DateTime.truncate(:second)
               },
               actor: context.actor
             )
             |> Ash.update(authorize?: false, context: context)

    assert initialized.status == "initialized"

    transitions =
      StateTransition
      |> Query.for_read(:list_for_entity, %{
        entity_type: "PaymentAttempt",
        entity_id: to_string(attempt.id)
      })
      |> Ash.read!(authorize?: false)

    assert Enum.any?(transitions, &(&1.to_state == "initializing"))
    assert Enum.any?(transitions, &(&1.to_state == "initialized"))
  end

  test "mark_failed transitions from initializing" do
    order_id = insert_order!()
    context = %{actor: Fixtures.system_actor(), correlation_id: "corr-fail-1"}

    {:ok, attempt} =
      PaymentAttempt
      |> Changeset.for_create(
        :create_initializing,
        %{
          sales_order_id: order_id,
          provider: "paystack",
          provider_reference: "FC-FAIL-1",
          idempotency_key: "paystack:init:#{order_id}:2",
          amount_cents: 5_000,
          currency: "ZAR"
        },
        actor: context.actor
      )
      |> Ash.create(authorize?: false, context: context)

    assert {:ok, failed} =
             attempt
             |> Changeset.for_update(
               :mark_failed,
               %{failure_code: "provider_error", failure_message: "safe failure"},
               actor: context.actor
             )
             |> Ash.update(authorize?: false, context: context)

    assert failed.status == "failed"
  end

  defp insert_order! do
    result =
      FastCheck.Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, source_channel, status, total_amount_cents, currency,
           lock_version, inserted_at, updated_at)
        VALUES
          ($1, $2, 'test', 'awaiting_payment', 10000, 'ZAR', 1, now(), now())
        RETURNING id
        """,
        ["FC-#{System.unique_integer([:positive])}", Fixtures.event_id()]
      )

    [[id]] = result.rows
    id
  end
end
