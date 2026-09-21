defmodule FastCheck.Sales.OfferManagement do
  @moduledoc """
  Admin orchestration boundary for WhatsApp-compatible ticket offer management.

  LiveView and other admin surfaces call this module instead of mutating
  `TicketOffer` or `ReservationLedger` directly.
  """

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Events
  alias FastCheck.Repo
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.MoneyInput
  alias FastCheck.Sales.TicketOffer

  @max_per_order_limit 9
  @currency "ZAR"

  @type dashboard_user :: %{required(:username) => String.t(), optional(:id) => String.t()}

  @spec admin_actor_from_user(dashboard_user(), pos_integer()) :: map()
  def admin_actor_from_user(%{username: username}, event_id) do
    %{actor_type: :admin, user_id: username, allowed_event_ids: [event_id]}
  end

  @spec parse_event_id(term()) :: {:ok, pos_integer()} | {:error, :invalid_event_id}
  def parse_event_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_event_id}
    end
  end

  def parse_event_id(value) when is_integer(value) and value > 0, do: {:ok, value}
  def parse_event_id(_), do: {:error, :invalid_event_id}

  @spec fetch_event_context(pos_integer()) ::
          {:ok, %{event: struct(), archived?: boolean()}} | {:error, :not_found}
  def fetch_event_context(event_id) when is_integer(event_id) and event_id > 0 do
    case Events.get_event_with_stats(event_id) do
      %{status: "archived"} = event -> {:ok, %{event: event, archived?: true}}
      event -> {:ok, %{event: event, archived?: false}}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def fetch_event_context(_), do: {:error, :not_found}

  @spec list_offers(map(), pos_integer()) :: {:ok, [struct()]} | {:error, term()}
  def list_offers(actor, event_id) do
    with {:ok, _} <- fetch_event_context(event_id) do
      TicketOffer
      |> Query.for_read(:list_manageable_for_event, %{event_id: event_id}, actor: actor)
      |> Ash.read(authorize?: true)
    end
  end

  @spec create_offer(map(), pos_integer(), map()) ::
          {:ok, struct()} | {:error, term()}
  def create_offer(actor, event_id, params) when is_map(params) do
    with :ok <- ensure_manageable_event(event_id),
         {:ok, attrs} <- build_create_attrs(event_id, params),
         {:ok, offer} <- create_disabled_offer(actor, attrs),
         {:ok, init_result} <- initialize_inventory_for_create(offer),
         {:ok, offer} <- maybe_enable_after_create_init(actor, offer, params, init_result) do
      {:ok, offer}
    else
      {:error, :inventory_initialization_failed} = error ->
        error

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec update_offer(map(), pos_integer(), pos_integer(), map()) ::
          {:ok, struct()} | {:error, term()}
  def update_offer(actor, event_id, offer_id, params) when is_map(params) do
    with :ok <- ensure_manageable_event(event_id),
         {:ok, offer} <- fetch_manageable_offer(actor, event_id, offer_id),
         :ok <- validate_submitted_lock_version(offer, params),
         {:ok, attrs} <- build_update_attrs(offer, params) do
      persist_offer_update(actor, offer, attrs)
    end
  end

  @spec enable_offer(map(), pos_integer(), pos_integer()) ::
          {:ok, struct()} | {:error, term()}
  def enable_offer(actor, event_id, offer_id) do
    with :ok <- ensure_manageable_event(event_id),
         {:ok, offer} <- fetch_manageable_offer(actor, event_id, offer_id),
         :ok <- ensure_inventory_ready_for_enable(offer) do
      persist_enable(actor, offer)
    end
  end

  @spec disable_offer(map(), pos_integer(), pos_integer()) ::
          {:ok, struct()} | {:error, term()}
  def disable_offer(actor, event_id, offer_id) do
    with :ok <- ensure_manageable_event(event_id),
         {:ok, offer} <- fetch_manageable_offer(actor, event_id, offer_id) do
      persist_disable(actor, offer)
    end
  end

  @spec retry_inventory_initialization(map(), pos_integer(), pos_integer()) ::
          {:ok, struct()} | {:error, term()}
  def retry_inventory_initialization(actor, event_id, offer_id) do
    with :ok <- ensure_manageable_event(event_id),
         {:ok, offer} <- fetch_manageable_offer(actor, event_id, offer_id),
         :ok <- ensure_safe_retry_allowed(offer),
         :ok <- initialize_inventory_for_retry(offer) do
      {:ok, offer}
    end
  end

  @spec safe_error_message(term()) :: String.t()
  def safe_error_message(:not_found), do: "Event not found."
  def safe_error_message(:invalid_event_id), do: "Invalid event identifier."
  def safe_error_message(:event_archived), do: "Archived events cannot be changed."
  def safe_error_message(:offer_not_found), do: "Ticket offer not found."
  def safe_error_message(:invalid_name), do: "Enter a ticket name."

  def safe_error_message(:invalid_money),
    do: "Enter a valid ZAR amount with at most two decimals."

  def safe_error_message(:invalid_quantity),
    do: "Initial inventory must be a positive whole number."

  def safe_error_message(:invalid_max_per_order), do: "Max per order must be between 1 and 9."

  def safe_error_message(:max_per_order_exceeds_inventory),
    do: "Max per order cannot exceed inventory."

  def safe_error_message(:inventory_initialization_failed),
    do:
      "Offer saved as disabled because live inventory could not be initialized. Retry setup when Redis is available."

  def safe_error_message(:inventory_not_ready),
    do: "Live inventory is missing or inconsistent. Reconcile inventory before enabling sales."

  def safe_error_message(:inventory_retry_not_allowed),
    do: "Inventory setup cannot be retried safely for this offer."

  def safe_error_message(:stale_offer),
    do: "This offer changed elsewhere. Review the latest details and try again."

  def safe_error_message(:forbidden), do: "You are not allowed to manage offers for this event."

  def safe_error_message(_),
    do: "Unable to save ticket offer changes. Check the details and try again."

  @spec derive_ticket_type(String.t()) :: String.t()
  def derive_ticket_type(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "ticket"
      ticket_type -> ticket_type
    end
  end

  defp ensure_manageable_event(event_id) do
    case fetch_event_context(event_id) do
      {:ok, %{archived?: true}} -> {:error, :event_archived}
      {:ok, _} -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp build_create_attrs(event_id, params) do
    with {:ok, name} <- required_string(params, "name", :invalid_name),
         {:ok, price_cents} <- parse_money_param(params, "price"),
         {:ok, regular_price_cents} <- parse_optional_money_param(params, "regular_price"),
         {:ok, quantity} <- parse_positive_int(params, "initial_quantity", :invalid_quantity),
         {:ok, max_per_order} <- parse_max_per_order(params, quantity) do
      {:ok,
       %{
         event_id: event_id,
         name: name,
         ticket_type: derive_ticket_type(name),
         price_cents: price_cents,
         regular_price_cents: regular_price_cents,
         currency: @currency,
         configured_quantity_available: quantity,
         initial_quantity: quantity,
         max_per_order: max_per_order,
         sales_enabled: false,
         sales_channel: "whatsapp",
         starts_at: nil,
         ends_at: nil
       }}
    end
  end

  defp build_update_attrs(offer, params) do
    with {:ok, name} <- required_string(params, "name", :invalid_name),
         {:ok, price_cents} <- parse_money_param(params, "price"),
         {:ok, regular_price_cents} <- parse_optional_money_param(params, "regular_price"),
         {:ok, max_per_order} <-
           parse_max_per_order(params, offer.configured_quantity_available) do
      attrs = %{
        name: name,
        price_cents: price_cents,
        regular_price_cents: regular_price_cents,
        max_per_order: max_per_order
      }

      {:ok, attrs}
    end
  end

  defp create_disabled_offer(actor, attrs) do
    TicketOffer
    |> Changeset.for_create(:create_offer, attrs, actor: actor)
    |> Ash.create(authorize?: true)
  end

  defp persist_offer_update(actor, offer, attrs) do
    offer
    |> Changeset.for_update(:update_offer, attrs, actor: actor)
    |> Ash.update(authorize?: true)
    |> map_stale_error()
  end

  defp persist_enable(actor, offer) do
    offer
    |> Changeset.for_update(:enable_sales, %{}, actor: actor)
    |> Ash.update(authorize?: true)
    |> map_stale_error()
  end

  defp persist_disable(actor, offer) do
    offer
    |> Changeset.for_update(:disable_sales, %{}, actor: actor)
    |> Ash.update(authorize?: true)
    |> map_stale_error()
  end

  defp maybe_enable_after_create_init(actor, offer, params, init_result) do
    if truthy?(Map.get(params, "sales_enabled")) and init_result == :initialized do
      with :ok <- ensure_inventory_ready_for_enable(offer) do
        persist_enable(actor, offer)
      end
    else
      {:ok, offer}
    end
  end

  defp initialize_inventory_for_create(%{id: offer_id, configured_quantity_available: quantity}) do
    case ReservationLedger.initialize_offer_if_absent(offer_id, quantity) do
      :ok -> {:ok, :initialized}
      {:error, :already_initialized, _} -> {:ok, :already_present}
      {:error, _, _} -> {:error, :inventory_initialization_failed}
    end
  end

  defp initialize_inventory_for_retry(%{id: offer_id, configured_quantity_available: quantity}) do
    case ReservationLedger.initialize_offer_if_absent(offer_id, quantity) do
      :ok -> :ok
      {:error, :already_initialized, _} -> {:error, :inventory_retry_not_allowed}
      {:error, _, _} -> {:error, :inventory_initialization_failed}
    end
  end

  defp ensure_inventory_ready_for_enable(offer) do
    case ReservationLedger.get_availability(offer.id) do
      {:ok,
       %{
         configured_quantity: configured,
         ledger_state: :healthy
       }} ->
        if configured == offer.configured_quantity_available do
          :ok
        else
          {:error, :inventory_not_ready}
        end

      {:ok, %{ledger_state: ledger_state}}
      when ledger_state in [:reconciliation_required, :unknown] ->
        {:error, :inventory_not_ready}

      {:error, _, _} ->
        {:error, :inventory_not_ready}
    end
  end

  defp ensure_safe_retry_allowed(offer) do
    cond do
      offer.sales_enabled ->
        {:error, :inventory_retry_not_allowed}

      not is_nil(offer.archived_at) ->
        {:error, :inventory_retry_not_allowed}

      order_line_exists?(offer.id) ->
        {:error, :inventory_retry_not_allowed}

      true ->
        case ReservationLedger.get_availability(offer.id) do
          {:error, :reconciliation_required, _} -> :ok
          {:error, _, _} -> {:error, :inventory_retry_not_allowed}
          {:ok, _} -> {:error, :inventory_retry_not_allowed}
        end
    end
  end

  defp order_line_exists?(offer_id) do
    from(ol in "sales_order_lines", where: ol.ticket_offer_id == ^offer_id, select: 1, limit: 1)
    |> Repo.one()
    |> case do
      nil -> false
      _ -> true
    end
  end

  defp fetch_manageable_offer(actor, event_id, offer_id) do
    case TicketOffer
         |> Query.for_read(:list_manageable_for_event, %{event_id: event_id}, actor: actor)
         |> Ash.read(authorize?: true) do
      {:ok, offers} ->
        case Enum.find(offers, &(&1.id == offer_id)) do
          nil -> {:error, :offer_not_found}
          offer -> {:ok, offer}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_money_param(params, key) do
    case blank_to_nil(Map.get(params, key)) do
      nil -> {:error, :invalid_money}
      value -> MoneyInput.parse_zar_to_cents(value)
    end
  end

  defp parse_optional_money_param(params, key) do
    case blank_to_nil(Map.get(params, key)) do
      nil -> {:ok, nil}
      value -> MoneyInput.parse_zar_to_cents(value)
    end
  end

  defp parse_max_per_order(params, configured_quantity) do
    with {:ok, max_per_order} <-
           parse_positive_int(params, "max_per_order", :invalid_max_per_order) do
      cond do
        max_per_order > @max_per_order_limit ->
          {:error, :invalid_max_per_order}

        max_per_order > configured_quantity ->
          {:error, :max_per_order_exceeds_inventory}

        true ->
          {:ok, max_per_order}
      end
    end
  end

  defp parse_positive_int(params, key, error_atom) do
    case blank_to_nil(Map.get(params, key)) do
      nil ->
        {:error, error_atom}

      value ->
        case Integer.parse(value) do
          {int, ""} when int > 0 -> {:ok, int}
          _ -> {:error, error_atom}
        end
    end
  end

  defp required_string(params, key, error_atom) do
    case blank_to_nil(Map.get(params, key)) do
      nil -> {:error, error_atom}
      value -> {:ok, value}
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_), do: false

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(value), do: value

  defp map_stale_error({:error, %Ash.Error.Invalid{errors: errors}}) do
    if Enum.any?(errors, &stale_lock_error?/1) do
      {:error, :stale_offer}
    else
      {:error, :invalid_offer}
    end
  end

  defp map_stale_error(other), do: other

  defp stale_lock_error?(%{message: message}) when is_binary(message),
    do: String.contains?(message, "lock_version") or String.contains?(message, "stale")

  defp stale_lock_error?(_), do: false

  defp validate_submitted_lock_version(offer, params) do
    case parse_lock_version(Map.get(params, "lock_version")) do
      {:ok, version} ->
        if version == offer.lock_version, do: :ok, else: {:error, :stale_offer}

      :error ->
        {:error, :stale_offer}
    end
  end

  defp parse_lock_version(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_lock_version(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {version, ""} when version > 0 -> {:ok, version}
      _ -> :error
    end
  end

  defp parse_lock_version(_), do: :error
end
