defmodule FastCheck.Observability.StateTransitionSupportRedactionTest do
  use FastCheck.DataCase, async: true

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.StateTransition
  alias FastCheck.Sales.StateTransitionSupport
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  test "metadata drops PII, tokens, and idempotency_key while top-level idempotency_key persists" do
    actor = Fixtures.system_actor()
    idempotency_key = "idem-#{System.unique_integer([:positive])}"

    order =
      Order
      |> Changeset.for_create(
        :create_draft,
        %{
          public_reference: "FC-redact-#{System.unique_integer([:positive])}",
          event_id: Fixtures.event_id(),
          source_channel: "test",
          total_amount_cents: 1000,
          currency: "ZAR",
          idempotency_key: idempotency_key
        },
        actor: actor
      )
      |> Ash.create!(authorize?: false)

    assert {:ok, _transition} =
             StateTransitionSupport.record!(
               %{
                 entity_type: "Order",
                 entity_id: to_string(order.id),
                 from_state: "draft",
                 to_state: "awaiting_payment",
                 metadata: %{
                   hold_token: "hold-secret",
                   idempotency_key: "metadata-idem",
                   buyer_name: "Secret Name",
                   buyer_phone: "+27111111111",
                   buyer_email: "secret@example.com",
                   status: "ok"
                 },
                 correlation_id: "corr-1",
                 idempotency_key: idempotency_key,
                 source: "test"
               },
               %{actor: actor}
             )

    transitions =
      StateTransition
      |> Query.for_read(:list_for_entity, %{entity_type: "Order", entity_id: to_string(order.id)})
      |> Ash.read!(authorize?: false)

    transition = Enum.find(transitions, &(&1.source == "test"))

    assert transition.idempotency_key == idempotency_key
    assert transition.metadata == %{"status" => "ok"}
    refute Map.has_key?(transition.metadata, "hold_token")
    refute Map.has_key?(transition.metadata, "idempotency_key")
    refute Map.has_key?(transition.metadata, "buyer_name")
    refute Map.has_key?(transition.metadata, "buyer_phone")
    refute Map.has_key?(transition.metadata, "buyer_email")
  end
end
