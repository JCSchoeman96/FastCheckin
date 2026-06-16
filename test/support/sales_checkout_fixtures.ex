defmodule FastCheck.SalesCheckoutFixtures do
  @moduledoc false

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

    Map.merge(base, overrides)
  end

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
