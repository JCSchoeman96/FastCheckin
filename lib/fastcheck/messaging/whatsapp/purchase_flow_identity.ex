defmodule FastCheck.Messaging.WhatsApp.PurchaseFlowIdentity do
  @moduledoc """
  Builds durable checkout identities for one WhatsApp purchase attempt.
  """

  @spec new() :: Ecto.UUID.t()
  def new, do: Ecto.UUID.generate()

  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> true
      _ -> false
    end
  end

  def valid?(_value), do: false

  @spec checkout_idempotency_key(pos_integer(), term()) ::
          {:ok, String.t()} | {:error, :invalid_conversation_id | :invalid_purchase_flow_id}
  def checkout_idempotency_key(conversation_id, purchase_flow_id) do
    cond do
      not (is_integer(conversation_id) and conversation_id > 0) ->
        {:error, :invalid_conversation_id}

      not valid?(purchase_flow_id) ->
        {:error, :invalid_purchase_flow_id}

      true ->
        {:ok, "whatsapp:conversation:#{conversation_id}:purchase:#{purchase_flow_id}:checkout"}
    end
  end

  @spec legacy_checkout_idempotency_key(pos_integer()) :: String.t()
  def legacy_checkout_idempotency_key(conversation_id) when is_integer(conversation_id) do
    "whatsapp:conversation:#{conversation_id}:checkout"
  end
end
