defmodule FastCheck.Sales.SecondaryEntrypoints do
  @moduledoc """
  Thin secondary-channel adapters for FastCheck Sales checkout entrypoints.

  Normalizes admin-assisted and internal-pilot input, maps `source_channel`
  server-side, and delegates all checkout creation to
  `FastCheck.Sales.Checkout.start_checkout/3`.
  """

  alias FastCheck.Events
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.TicketOffer

  @type dashboard_user :: %{required(:username) => String.t(), optional(:id) => String.t()}

  @spec generate_idempotency_key() :: String.t()
  def generate_idempotency_key do
    "sec-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  @spec parse_event_id(term()) :: {:ok, pos_integer()} | {:error, :invalid}
  def parse_event_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> {:ok, int}
      _ -> {:error, :invalid}
    end
  end

  def parse_event_id(value) when is_integer(value) and value > 0, do: {:ok, value}
  def parse_event_id(_), do: {:error, :invalid}

  @spec safe_fetch_event(pos_integer()) :: {:ok, struct()} | {:error, :not_found}
  def safe_fetch_event(event_id) when is_integer(event_id) and event_id > 0 do
    {:ok, Events.get_event_with_stats(event_id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def safe_fetch_event(_), do: {:error, :not_found}

  @spec internal_pilot_enabled?() :: boolean()
  def internal_pilot_enabled? do
    Application.get_env(:fastcheck, :sales_internal_pilot_enabled, false)
  end

  @spec list_offers_for_channel(map(), pos_integer(), String.t()) ::
          {:ok, [struct()]} | {:error, term()}
  def list_offers_for_channel(actor, event_id, sales_channel)
      when is_integer(event_id) and is_binary(sales_channel) do
    TicketOffer
    |> Ash.Query.for_read(
      :list_active_for_event,
      %{
        event_id: event_id,
        sales_channel: sales_channel,
        as_of: DateTime.utc_now()
      },
      actor: actor
    )
    |> Ash.read(authorize?: true)
  end

  @spec admin_actor_from_user(dashboard_user(), pos_integer()) :: map()
  def admin_actor_from_user(%{username: username}, event_id) do
    %{actor_type: :admin, user_id: username, allowed_event_ids: [event_id]}
  end

  @spec start_admin_checkout(dashboard_user(), pos_integer(), map(), String.t()) ::
          {:ok, %{order_id: integer(), public_reference: String.t()}} | {:error, term()}
  def start_admin_checkout(user, event_id, params, idempotency_key) do
    start_checkout(user, event_id, params, idempotency_key, "admin")
  end

  @spec start_internal_pilot_checkout(dashboard_user(), pos_integer(), map(), String.t()) ::
          {:ok, %{order_id: integer(), public_reference: String.t()}} | {:error, term()}
  def start_internal_pilot_checkout(user, event_id, params, idempotency_key) do
    if internal_pilot_enabled?() do
      start_checkout(user, event_id, params, idempotency_key, "internal_pilot")
    else
      {:error, :pilot_disabled}
    end
  end

  @spec safe_error_message(term()) :: String.t()
  def safe_error_message(:not_found), do: "Event not found."
  def safe_error_message(:pilot_disabled), do: "Internal pilot checkout is not enabled."
  def safe_error_message(:invalid_quantity), do: "Enter a valid quantity."
  def safe_error_message(:invalid_offer), do: "Select a valid ticket offer."
  def safe_error_message(:sales_disabled), do: "This offer is not available for sale."
  def safe_error_message(:sales_window_closed), do: "Sales for this offer are not open."

  def safe_error_message(:sales_channel_unavailable),
    do: "This offer is not available on this channel."

  def safe_error_message(:max_per_order_exceeded),
    do: "Quantity exceeds the maximum allowed per order."

  def safe_error_message(:insufficient_inventory),
    do: "Not enough tickets are available right now."

  def safe_error_message(:inventory_unavailable),
    do: "Inventory is temporarily unavailable. Try again shortly."

  def safe_error_message(:forbidden), do: "You are not allowed to start this checkout."

  def safe_error_message(:duplicate_idempotency_conflict),
    do: "This checkout request conflicts with a prior attempt."

  def safe_error_message(_), do: "Unable to start checkout. Check the details and try again."

  defp start_checkout(user, event_id, params, idempotency_key, source_channel) do
    with {:ok, _event} <- safe_fetch_event(event_id),
         {:ok, input} <- build_checkout_input(params, event_id, idempotency_key, source_channel) do
      actor = admin_actor_from_user(user, event_id)

      case Checkout.start_checkout(input, actor, []) do
        {:ok, %{order: order}} ->
          {:ok, %{order_id: order.id, public_reference: order.public_reference}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_checkout_input(params, event_id, idempotency_key, source_channel) do
    with {:ok, event} <- safe_fetch_event(event_id),
         {:ok, ticket_offer_id} <- parse_offer_id(params),
         {:ok, quantity} <- parse_quantity(params) do
      {:ok,
       %{
         event_id: event_id,
         ticket_offer_id: ticket_offer_id,
         quantity: quantity,
         buyer_name: blank_to_nil(param(params, "buyer_name")),
         buyer_phone: blank_to_nil(param(params, "buyer_phone")),
         buyer_email: blank_to_nil(param(params, "buyer_email")),
         source_channel: source_channel,
         idempotency_key: idempotency_key,
         event_name: event.name
       }}
    else
      {:error, :invalid} -> {:error, :invalid_offer}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_offer_id(params) do
    case param(params, "ticket_offer_id") do
      nil -> {:error, :invalid}
      value -> parse_positive_int(value)
    end
  end

  defp parse_quantity(params) do
    case param(params, "quantity") do
      nil -> {:error, :invalid_quantity}
      value -> parse_positive_int(value)
    end
  end

  defp parse_positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} when int > 0 -> {:ok, int}
      _ -> {:error, :invalid}
    end
  end

  defp parse_positive_int(_), do: {:error, :invalid}

  defp param(params, key) when is_map(params) and is_binary(key) do
    Map.get(params, key) || Map.get(params, safe_existing_atom(key))
  end

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(_), do: nil
end
