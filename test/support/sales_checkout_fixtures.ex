defmodule FastCheck.SalesCheckoutFixtures do
  @moduledoc false

  import Ecto.Query

  alias FastCheck.Events
  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.TicketOffer

  @event_id 55_001

  def event_id, do: @event_id

  def system_actor(event_ids \\ [@event_id]) do
    %{actor_type: :system, actor_id: "system-1", allowed_event_ids: List.wrap(event_ids)}
  end

  def admin_actor(event_ids \\ [@event_id]) do
    %{actor_type: :admin, user_id: "admin-1", allowed_event_ids: List.wrap(event_ids)}
  end

  def operator_actor(event_ids \\ [@event_id]) do
    %{actor_type: :operator, user_id: "operator-1", allowed_event_ids: List.wrap(event_ids)}
  end

  def customer_session_actor(event_ids \\ [@event_id]) do
    %{
      actor_type: :customer_session,
      actor_id: "customer-1",
      allowed_event_ids: List.wrap(event_ids)
    }
  end

  def checkout_input(overrides \\ %{}) do
    skip_lock_version? = Map.get(overrides, :skip_whatsapp_lock_version, false)
    overrides = Map.delete(overrides, :skip_whatsapp_lock_version)

    base = %{
      event_id: @event_id,
      ticket_offer_id: nil,
      quantity: 1,
      buyer_name: "Test Buyer",
      buyer_phone: "+27123456789",
      buyer_email: "buyer@example.com",
      source_channel: "test",
      idempotency_key: "idem-#{System.unique_integer([:positive])}",
      correlation_id: "corr-#{System.unique_integer([:positive])}",
      event_name: "Test Event"
    }

    input = Map.merge(base, overrides)

    if skip_lock_version? do
      input
    else
      maybe_attach_whatsapp_lock_version(input)
    end
  end

  defp maybe_attach_whatsapp_lock_version(%{ticket_offer_id: offer_id} = input)
       when is_integer(offer_id) do
    if Map.has_key?(input, :expected_offer_lock_version) do
      input
    else
      case Repo.one(
             from(o in "sales_ticket_offers", where: o.id == ^offer_id, select: o.lock_version)
           ) do
        version when is_integer(version) ->
          Map.put(input, :expected_offer_lock_version, version)

        _ ->
          input
      end
    end
  end

  defp maybe_attach_whatsapp_lock_version(input), do: input

  def insert_offer!(opts \\ []) do
    event_id = Keyword.get(opts, :event_id, @event_id)
    sales_channel = Keyword.get(opts, :sales_channel, "whatsapp")
    sales_enabled = Keyword.get(opts, :sales_enabled, true)
    starts_at = Keyword.get(opts, :starts_at)
    ends_at = Keyword.get(opts, :ends_at)
    archived_at = Keyword.get(opts, :archived_at)
    max_per_order = Keyword.get(opts, :max_per_order, 2)
    price_cents = Keyword.get(opts, :price_cents, 10_000)
    name = Keyword.get(opts, :name, "Offer-#{System.unique_integer([:positive])}")
    configured = Keyword.get(opts, :configured_quantity_available, 100)

    event_missing? = is_nil(Repo.get(Event, event_id))

    if event_missing? do
      ensure_legacy_event!(event_id)
    end

    if event_missing? and sales_channel in ["whatsapp", "all"] do
      {:ok, _event} = Events.enable_whatsapp_sales(event_id)
    end

    result =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
           lock_version, archived_at, inserted_at, updated_at)
        VALUES
          ($1, $2, 'general', $3, 'ZAR', $4, $4, $5, $6, $7, $8, $9, 1, $10, now(), now())
        RETURNING id
        """,
        [
          event_id,
          name,
          price_cents,
          configured,
          max_per_order,
          sales_enabled,
          sales_channel,
          starts_at,
          ends_at,
          archived_at
        ]
      )

    [[id]] = result.rows

    offer =
      TicketOffer
      |> Ash.Query.for_read(:get_by_id, %{id: id}, actor: system_actor([event_id]))
      |> Ash.read_one!(authorize?: false)

    if Keyword.get(opts, :initialize_inventory, true) do
      :ok = ReservationLedger.initialize_offer(id, configured)
    end

    offer
  end

  @doc false
  def ensure_event_for_sales!(event_id) when is_integer(event_id) and event_id > 0 do
    ensure_legacy_event!(event_id)
  end

  defp ensure_legacy_event!(event_id) do
    case Repo.get(Event, event_id) do
      %Event{} ->
        :ok

      nil ->
        do_insert_legacy_event!(event_id)
        Repo.get!(Event, event_id)
        :ok
    end
  end

  defp do_insert_legacy_event!(event_id) do
    %Event{id: event_id}
    |> Event.changeset(%{
      name: "Checkout Fixture Event #{event_id}",
      site_url: "https://checkout-fixture.example.com",
      tickera_site_url: "https://checkout-fixture.example.com",
      tickera_api_key_encrypted: "checkout-fixture-api-key",
      mobile_access_secret_encrypted: "checkout-fixture-mobile-secret",
      scanner_login_code: legacy_scanner_login_code(event_id),
      status: "active",
      whatsapp_max_tickets_per_order: 10
    })
    |> Repo.insert!()
  end

  defp legacy_scanner_login_code(event_id) do
    suffix = rem(abs(event_id), 100_000) |> Integer.to_string() |> String.pad_leading(5, "0")
    code = suffix <> "A"

    if String.length(code) == 6 do
      code
    else
      String.slice(code, 0, 6) |> String.pad_leading(6, "0")
    end
  end

  def with_redis_stopped(fun) when is_function(fun, 0) do
    stop_redis_connection!()

    try do
      fun.()
    after
      start_redis_connection!()
    end
  end

  def stop_redis_connection! do
    case Supervisor.terminate_child(FastCheck.Supervisor, FastCheck.Redis.Connection) do
      :ok -> :ok
      {:ok, _pid} -> :ok
      {:error, :not_found} -> :ok
      other -> other
    end
  end

  def start_redis_connection! do
    case Supervisor.restart_child(FastCheck.Supervisor, FastCheck.Redis.Connection) do
      :ok -> :ok
      {:ok, _pid} -> :ok
      {:error, :already_started, _pid} -> :ok
      other -> other
    end

    wait_for_redis!()
  end

  defp wait_for_redis!(attempts \\ 20) do
    if Process.whereis(FastCheck.Redix) && redis_ping_ok?() do
      :ok
    else
      if attempts > 0 do
        Process.sleep(50)
        wait_for_redis!(attempts - 1)
      else
        raise "Redis connection did not restart for tests"
      end
    end
  end

  defp redis_ping_ok? do
    case Redix.command(FastCheck.Redix, ["PING"]) do
      {:ok, "PONG"} -> true
      _ -> false
    end
  end

  def flush_inventory_keys(offer_id) do
    keys = [
      "sales:offer:#{offer_id}:inventory",
      "sales:offer:#{offer_id}:holds",
      "sales:inventory:events:#{offer_id}"
    ]

    _ = Redix.command(FastCheck.Redix, ["DEL" | keys])
    scan_delete_all("sales:hold:*")
    scan_delete_all("sales:order:*:lock")
    scan_delete_all("sales:inventory:dedupe:*")
    :ok
  end

  defp scan_delete_all(pattern) do
    do_scan_delete_all("0", pattern)
  end

  defp do_scan_delete_all(cursor, pattern) do
    case Redix.command(FastCheck.Redix, ["SCAN", cursor, "MATCH", pattern, "COUNT", "500"]) do
      {:ok, [next_cursor, keys]} ->
        if keys != [], do: _ = Redix.command(FastCheck.Redix, ["DEL" | keys])

        if next_cursor == "0" do
          :ok
        else
          do_scan_delete_all(next_cursor, pattern)
        end

      _ ->
        :ok
    end
  end
end
