defmodule FastCheck.Sales.Checkout do
  @moduledoc """
  Approved checkout orchestration boundary for FastCheck Sales.

  All channel entrypoints must call `start_checkout/3`. Inventory mutation is
  delegated exclusively to `ReservationLedger`.
  """

  require Logger

  require Ash.Expr
  require Ash.Query
  import Ash.Expr

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.OrderLine
  alias FastCheck.Sales.TicketOffer

  @type checkout_input :: %{
          required(:event_id) => integer(),
          required(:ticket_offer_id) => integer(),
          required(:quantity) => integer(),
          optional(:buyer_name) => String.t() | nil,
          optional(:buyer_phone) => String.t() | nil,
          optional(:buyer_email) => String.t() | nil,
          required(:source_channel) => String.t(),
          required(:idempotency_key) => String.t(),
          optional(:correlation_id) => String.t() | nil,
          required(:event_name) => String.t()
        }

  @checkout_actor_types [:system, :admin, :customer_session]

  @spec start_checkout(checkout_input(), map(), keyword()) ::
          {:ok, %{order: struct(), checkout_session: struct()}}
          | {:error, atom()}
  def start_checkout(input, actor, opts \\ []) do
    input = Map.new(input)
    context = build_context(actor, input, opts)

    with :ok <- validate_quantity(input),
         {:ok, existing_order} <- lookup_idempotent_order(input) do
      if existing_order && not idempotent_inputs_match?(existing_order, input, opts) do
        {:error, :duplicate_idempotency_conflict}
      else
        with :ok <- authorize_actor(actor, input),
             :ok <- validate_effective_sales_channel(input, opts) do
          if existing_order do
            build_idempotent_replay(existing_order)
          else
            with {:ok, offer} <- validate_offer(input, opts, context),
                 :ok <- validate_quantity_against_offer(input, offer) do
              create_checkout(offer, input, actor, context)
            end
          end
        end
      end
    end
  end

  defp build_context(actor, input, opts) do
    effective_channel = effective_sales_channel(Map.get(input, :source_channel), opts)

    %{
      actor: actor,
      correlation_id: Map.get(input, :correlation_id),
      source_channel: Map.get(input, :source_channel),
      transition_metadata: %{
        source_channel: Map.get(input, :source_channel),
        effective_sales_channel: effective_channel
      },
      effective_sales_channel: effective_channel
    }
  end

  defp authorize_actor(%{actor_type: actor_type, allowed_event_ids: ids}, %{event_id: event_id})
       when actor_type in @checkout_actor_types and is_list(ids) do
    if event_id in ids, do: :ok, else: {:error, :forbidden}
  end

  defp authorize_actor(%{actor_type: :system}, %{event_id: _}), do: :ok

  defp authorize_actor(_, _), do: {:error, :forbidden}

  defp validate_effective_sales_channel(%{source_channel: channel}, opts)
       when channel in ["system", "test"] do
    case effective_sales_channel(channel, opts) do
      nil -> {:error, :invalid_effective_sales_channel}
      _ -> :ok
    end
  end

  defp validate_effective_sales_channel(_input, _opts), do: :ok

  defp validate_quantity(%{quantity: quantity}) when is_integer(quantity) and quantity > 0,
    do: :ok

  defp validate_quantity(_), do: {:error, :invalid_quantity}

  defp validate_quantity_against_offer(%{quantity: quantity}, %{max_per_order: max}) do
    if quantity > max, do: {:error, :max_per_order_exceeded}, else: :ok
  end

  defp lookup_idempotent_order(%{idempotency_key: key}) when is_binary(key) and key != "" do
    Order
    |> Query.for_read(:get_by_idempotency_key, %{idempotency_key: key})
    |> Ash.read_one(authorize?: false)
  end

  defp lookup_idempotent_order(_input), do: {:ok, nil}

  defp build_idempotent_replay(order) do
    case {order.status, load_checkout_session(order)} do
      {"awaiting_payment", {:ok, %{status: "hold_attached"} = session}} ->
        {:ok, %{order: order, checkout_session: sanitize_session(session)}}

      _ ->
        {:error, :duplicate_idempotency_conflict}
    end
  end

  defp idempotent_inputs_match?(order, input, opts) do
    case load_primary_order_line(order) do
      {:ok, line} ->
        stored_effective_channel = metadata_value(line.metadata, :effective_sales_channel)

        effective_channel =
          stored_effective_channel || effective_sales_channel(order.source_channel, [])

        order.event_id == Map.get(input, :event_id) and
          order.source_channel == Map.get(input, :source_channel) and
          line.ticket_offer_id == Map.get(input, :ticket_offer_id) and
          line.quantity == Map.get(input, :quantity) and
          line.event_name_snapshot == Map.get(input, :event_name) and
          effective_channel == effective_sales_channel(Map.get(input, :source_channel), opts) and
          buyer_fields_match?(order, input)

      _ ->
        false
    end
  end

  defp load_primary_order_line(order) do
    case OrderLine
         |> Query.for_read(:list_for_order, %{sales_order_id: order.id})
         |> Ash.read(authorize?: false) do
      {:ok, [line]} -> {:ok, line}
      {:ok, _} -> {:error, :invalid_order_state}
      {:error, _} = error -> error
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_, _), do: nil

  defp buyer_fields_match?(order, input) do
    Map.get(input, :buyer_name) == order.buyer_name and
      Map.get(input, :buyer_phone) == order.buyer_phone and
      Map.get(input, :buyer_email) == order.buyer_email
  end

  defp load_checkout_session(order) do
    order_id = order.id

    CheckoutSession
    |> Query.filter(expr(sales_order_id == ^order_id))
    |> Ash.read_one(authorize?: false)
  end

  defp validate_offer(input, opts, _context) do
    offer_id = Map.fetch!(input, :ticket_offer_id)
    event_id = Map.fetch!(input, :event_id)
    as_of = DateTime.utc_now() |> DateTime.truncate(:second)
    effective_channel = effective_sales_channel(Map.get(input, :source_channel), opts)

    case load_offer(offer_id) do
      {:ok, nil} -> {:error, :offer_not_found}
      {:ok, offer} -> validate_offer_record(offer, event_id, as_of, effective_channel)
      {:error, _} = error -> error
    end
  end

  defp load_offer(offer_id) do
    system_actor = %{actor_type: :system, actor_id: "checkout", allowed_event_ids: []}

    TicketOffer
    |> Query.for_read(:get_by_id, %{id: offer_id}, actor: system_actor)
    |> Ash.read_one(authorize?: false)
  end

  defp validate_offer_record(offer, event_id, as_of, effective_channel) do
    cond do
      offer.event_id != event_id ->
        {:error, :offer_not_found}

      not is_nil(offer.archived_at) or offer.sales_enabled != true ->
        {:error, :sales_disabled}

      not window_open?(offer, as_of) ->
        {:error, :sales_window_closed}

      not channel_allowed?(offer.sales_channel, effective_channel) ->
        {:error, :sales_channel_unavailable}

      true ->
        {:ok, offer}
    end
  end

  defp window_open?(offer, as_of) do
    starts_ok = is_nil(offer.starts_at) or DateTime.compare(offer.starts_at, as_of) != :gt
    ends_ok = is_nil(offer.ends_at) or DateTime.compare(offer.ends_at, as_of) == :gt
    starts_ok and ends_ok
  end

  defp channel_allowed?(offer_channel, effective_channel) do
    offer_channel == "all" or offer_channel == effective_channel
  end

  defp effective_sales_channel("whatsapp", _opts), do: "whatsapp"
  defp effective_sales_channel("admin", _opts), do: "admin"
  defp effective_sales_channel("web", _opts), do: "web"
  defp effective_sales_channel("internal_pilot", _opts), do: "internal"

  defp effective_sales_channel(channel, opts) when channel in ["system", "test"] do
    Keyword.get(opts, :effective_sales_channel)
  end

  defp effective_sales_channel(_, _), do: nil

  defp create_checkout(offer, input, actor, context) do
    ttl_seconds = hold_ttl_seconds()
    public_reference = generate_public_reference()
    total_cents = offer.price_cents * Map.fetch!(input, :quantity)

    expires_at =
      DateTime.add(DateTime.utc_now(), ttl_seconds, :second) |> DateTime.truncate(:second)

    with {:ok, order} <-
           create_draft_order(
             offer,
             input,
             public_reference,
             total_cents,
             expires_at,
             actor,
             context
           ),
         {:ok, _line} <- create_order_line(offer, order, input, actor, context),
         :ok <- confirm_order_checkout(order, actor, context),
         {:ok, session} <- create_checkout_session(order, actor, context),
         {:ok, hold} <- reserve_inventory(offer, order, input, ttl_seconds),
         {:ok, session} <- attach_hold(session, order, offer, hold, actor, context),
         {:ok, order} <- mark_order_awaiting_payment(order, offer, expires_at, actor, context) do
      log_checkout_success(order, offer)
      {:ok, %{order: order, checkout_session: sanitize_session(session)}}
    else
      {:error, :inventory_unavailable} = error ->
        error

      {:error, :insufficient_inventory} = error ->
        error

      {:error, _} = error ->
        error

      {:error, atom, _meta} when is_atom(atom) ->
        {:error, atom}
    end
  end

  defp create_draft_order(offer, input, public_reference, total_cents, expires_at, actor, context) do
    attrs = %{
      public_reference: public_reference,
      event_id: Map.fetch!(input, :event_id),
      buyer_name: Map.get(input, :buyer_name),
      buyer_phone: Map.get(input, :buyer_phone),
      buyer_email: Map.get(input, :buyer_email),
      source_channel: Map.get(input, :source_channel),
      total_amount_cents: total_cents,
      currency: offer.currency,
      idempotency_key: Map.get(input, :idempotency_key),
      expires_at: expires_at
    }

    Order
    |> Changeset.for_create(:create_draft, attrs, actor: actor)
    |> Ash.create(authorize?: false, context: context)
  end

  defp create_order_line(offer, order, input, actor, context) do
    quantity = Map.fetch!(input, :quantity)

    attrs = %{
      sales_order_id: order.id,
      ticket_offer_id: offer.id,
      line_number: 1,
      ticket_type: offer.ticket_type,
      offer_name_snapshot: offer.name,
      event_name_snapshot: Map.fetch!(input, :event_name),
      quantity: quantity,
      unit_amount_cents: offer.price_cents,
      total_amount_cents: offer.price_cents * quantity,
      currency: offer.currency,
      metadata: %{
        effective_sales_channel: Map.get(context, :effective_sales_channel)
      }
    }

    OrderLine
    |> Changeset.for_create(:create_for_order, attrs, actor: actor)
    |> Ash.create(authorize?: false, context: context)
  end

  defp confirm_order_checkout(order, actor, context) do
    order
    |> Changeset.for_update(:confirm_checkout, %{}, actor: actor)
    |> Ash.update(authorize?: false, context: context)
    |> case do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp create_checkout_session(order, actor, context) do
    CheckoutSession
    |> Changeset.for_create(:create_session, %{sales_order_id: order.id}, actor: actor)
    |> Ash.create(authorize?: false, context: context)
  end

  defp reserve_inventory(offer, order, input, ttl_seconds) do
    case ReservationLedger.reserve(
           offer.id,
           order.public_reference,
           Map.fetch!(input, :quantity),
           ttl_seconds,
           Map.fetch!(input, :idempotency_key)
         ) do
      {:ok, hold} ->
        {:ok, hold}

      {:error, :insufficient_inventory, _} ->
        {:error, :insufficient_inventory}

      {:error, _, _} ->
        {:error, :inventory_unavailable}
    end
  end

  defp attach_hold(session, order, offer, hold, actor, context) do
    hold_token_hash = hash_hold_token(:crypto.strong_rand_bytes(32))
    expires_at = ms_to_datetime(hold.expires_at)

    session
    |> Changeset.for_update(
      :attach_inventory_hold,
      %{
        redis_hold_key: ReservationLedger.hold_key(order.public_reference),
        hold_token: hold_token_hash,
        hold_quantity: hold.quantity,
        expires_at: expires_at
      },
      actor: actor
    )
    |> Ash.update(authorize?: false, context: context)
    |> case do
      {:ok, updated} ->
        {:ok, updated}

      {:error, _} = error ->
        _ = compensate_after_reserve_failure(order, offer.id, actor, context)
        error
    end
  end

  defp mark_order_awaiting_payment(order, offer, expires_at, actor, context) do
    order
    |> Changeset.for_update(:mark_awaiting_payment, %{expires_at: expires_at}, actor: actor)
    |> Ash.update(authorize?: false, context: context)
    |> case do
      {:ok, updated} ->
        {:ok, updated}

      {:error, _} = error ->
        _ = compensate_after_reserve_failure(order, offer.id, actor, context)
        error
    end
  end

  defp compensate_after_reserve_failure(order, offer_id, actor, context) do
    release_key = "release-#{order.public_reference}"

    case ReservationLedger.release(offer_id, order.public_reference, release_key) do
      {:ok, _} ->
        :ok

      {:error, _, _} ->
        move_to_manual_review(order, actor, context, "inventory_release_failed")
    end
  end

  defp move_to_manual_review(order, actor, context, reason) do
    _ =
      order
      |> Changeset.for_update(:mark_manual_review, %{last_error_code: reason},
        reason: reason,
        actor: actor
      )
      |> Ash.update(authorize?: false, context: context)

    case load_checkout_session(order) do
      {:ok, session} when not is_nil(session) ->
        _ =
          session
          |> Changeset.for_update(:mark_manual_review, %{}, reason: reason, actor: actor)
          |> Ash.update(authorize?: false, context: context)

      _ ->
        :ok
    end

    :ok
  end

  defp hash_hold_token(opaque_token) when is_binary(opaque_token) do
    pepper = Application.get_env(:fastcheck, :sales_hold_token_pepper, "test-pepper")

    :crypto.hash(:sha256, opaque_token <> pepper)
    |> Base.encode16(case: :lower)
  end

  defp generate_public_reference do
    "FC-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp hold_ttl_seconds do
    Application.get_env(:fastcheck, :sales_checkout_hold_ttl_seconds, 600)
  end

  defp ms_to_datetime(ms) when is_integer(ms) do
    DateTime.from_unix!(ms, :millisecond) |> DateTime.truncate(:second)
  end

  defp sanitize_session(session) do
    %{session | hold_token: nil}
  end

  defp log_checkout_success(order, offer) do
    Logger.info(
      "checkout_started order_id=#{order.id} offer_id=#{offer.id} public_reference=#{order.public_reference}"
    )
  end
end
