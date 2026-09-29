defmodule FastCheck.Messaging.WhatsApp.PurchaseFlowIdentityTest do
  use ExUnit.Case, async: true

  alias FastCheck.Messaging.WhatsApp.PurchaseFlowIdentity

  test "a purchase flow gets one canonical UUID and a flow-scoped checkout key" do
    purchase_flow_id = PurchaseFlowIdentity.new()

    assert PurchaseFlowIdentity.valid?(purchase_flow_id)
    assert {:ok, key} = PurchaseFlowIdentity.checkout_idempotency_key(42, purchase_flow_id)

    assert key ==
             "whatsapp:conversation:42:purchase:#{purchase_flow_id}:checkout"

    assert key != PurchaseFlowIdentity.legacy_checkout_idempotency_key(42)
  end

  test "separate genuine purchases get distinct checkout keys" do
    first_key =
      PurchaseFlowIdentity.new() |> then(&PurchaseFlowIdentity.checkout_idempotency_key(42, &1))

    second_key =
      PurchaseFlowIdentity.new() |> then(&PurchaseFlowIdentity.checkout_idempotency_key(42, &1))

    assert {:ok, first_key} = first_key
    assert {:ok, second_key} = second_key
    refute first_key == second_key
  end

  test "malformed flow identities cannot produce a modern checkout key" do
    refute PurchaseFlowIdentity.valid?("conversation-42")

    assert {:error, :invalid_purchase_flow_id} =
             PurchaseFlowIdentity.checkout_idempotency_key(42, "conversation-42")
  end
end
