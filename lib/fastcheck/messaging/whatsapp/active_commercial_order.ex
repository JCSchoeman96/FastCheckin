defmodule FastCheck.Messaging.WhatsApp.ActiveCommercialOrder do
  @moduledoc """
  Finds the one non-terminal Order that prevents a duplicate WhatsApp purchase.
  """

  import Ash.Expr

  require Ash.Expr
  require Ash.Query

  alias Ash.Query
  alias FastCheck.Messaging.WhatsApp.PurchaseFlowIdentity
  alias FastCheck.Sales.Order

  @active_statuses [
    "draft",
    "awaiting_payment",
    "payment_pending",
    "paid_unverified",
    "paid_verified",
    "fulfillment_queued",
    "partially_issued",
    "issuance_retry_queued",
    "manual_review",
    "manual_review_held"
  ]

  @spec active_statuses() :: [String.t()]
  def active_statuses, do: @active_statuses

  @spec find_active_order(map()) :: {:ok, Order.t() | nil} | {:error, term()}
  def find_active_order(%{id: conversation_id, state_data: state_data})
      when is_integer(conversation_id) and conversation_id > 0 do
    with {:ok, preferred_order} <- preferred_order(state_data, conversation_id),
         {:ok, orders} <- active_orders_for_conversation(conversation_id) do
      choose_active_order(preferred_order, orders)
    end
  end

  def find_active_order(_conversation), do: {:error, :conversation_order_mismatch}

  defp preferred_order(state_data, conversation_id) when is_map(state_data) do
    case Map.fetch(state_data, "sales_order_id") do
      :error ->
        identity_order(state_data, conversation_id)

      {:ok, nil} ->
        identity_order(state_data, conversation_id)

      {:ok, order_id} when is_integer(order_id) and order_id > 0 ->
        order_by_id(order_id) |> validate_conversation_order(conversation_id)

      {:ok, _invalid_id} ->
        {:error, :conversation_order_mismatch}
    end
  end

  defp preferred_order(_state_data, conversation_id) do
    identity_order(%{}, conversation_id)
  end

  defp identity_order(state_data, conversation_id) when is_map(state_data) do
    case Map.get(state_data, "purchase_flow_id") do
      purchase_flow_id when is_binary(purchase_flow_id) ->
        case PurchaseFlowIdentity.checkout_idempotency_key(conversation_id, purchase_flow_id) do
          {:ok, key} ->
            order_by_idempotency_key(key)
            |> validate_conversation_order(conversation_id)

          {:error, :invalid_purchase_flow_id} ->
            {:error, :conversation_order_mismatch}

          {:error, reason} ->
            {:error, reason}
        end

      nil ->
        key = PurchaseFlowIdentity.legacy_checkout_idempotency_key(conversation_id)
        order_by_idempotency_key(key) |> validate_conversation_order(conversation_id)

      _invalid_purchase_flow_id ->
        {:error, :conversation_order_mismatch}
    end
  end

  defp order_by_id(order_id) do
    Order
    |> Query.for_read(:get_by_id, %{id: order_id})
    |> Ash.read_one(authorize?: false)
    |> unwrap_order()
  end

  defp order_by_idempotency_key(key) do
    Order
    |> Query.for_read(:get_by_idempotency_key, %{idempotency_key: key})
    |> Ash.read_one(authorize?: false)
    |> unwrap_order()
  end

  defp unwrap_order({:ok, nil}), do: {:ok, nil}
  defp unwrap_order({:ok, order}), do: {:ok, order}
  defp unwrap_order({:error, reason}), do: {:error, reason}

  defp validate_conversation_order({:ok, nil}, _conversation_id), do: {:ok, nil}

  defp validate_conversation_order(
         {:ok, %{sales_conversation_id: conversation_id} = order},
         conversation_id
       ),
       do: {:ok, order}

  defp validate_conversation_order({:ok, _order}, _conversation_id),
    do: {:error, :conversation_order_mismatch}

  defp validate_conversation_order({:error, reason}, _conversation_id), do: {:error, reason}

  defp active_orders_for_conversation(conversation_id) do
    Order
    |> Query.filter(expr(sales_conversation_id == ^conversation_id))
    |> Query.filter(expr(status in ^@active_statuses))
    |> Query.limit(2)
    |> Ash.read(authorize?: false)
  end

  defp choose_active_order(_identity_order, [first, second | _rest]) do
    if first.id == second.id do
      {:ok, first}
    else
      {:error, :multiple_active_orders}
    end
  end

  defp choose_active_order(identity_order, []) do
    if active_order?(identity_order), do: {:ok, identity_order}, else: {:ok, nil}
  end

  defp choose_active_order(identity_order, [order]) do
    if active_order?(identity_order) and identity_order.id != order.id do
      {:error, :multiple_active_orders}
    else
      {:ok, order}
    end
  end

  defp active_order?(%{status: status}), do: status in @active_statuses
  defp active_order?(_order), do: false
end
