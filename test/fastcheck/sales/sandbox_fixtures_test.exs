defmodule FastCheck.Sales.SandboxFixturesTest do
  use FastCheck.DataCase, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Crypto
  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.SandboxFixtures
  alias FastCheck.Sales.TicketOffer
  alias FastCheck.SalesCheckoutFixtures

  @event_name_prefix "WhatsApp Sandbox Test Event"
  @event_shortname_prefix "WA Sandbox"
  @dummy_tickera_api_key "whatsapp-sandbox-dummy-tickera-api-key"
  @dummy_mobile_secret "whatsapp-sandbox-dummy-mobile-secret"

  setup do
    on_exit(fn ->
      SandboxFixtures
      |> Code.ensure_loaded()
      |> case do
        {:module, SandboxFixtures} ->
          SandboxFixtures.__info__(:functions)
          |> Keyword.has_key?(:ensure_whatsapp_checkout_fixture!)
          |> if do
            sandbox_offer_ids()
            |> Enum.each(&SalesCheckoutFixtures.flush_inventory_keys/1)
          end

        _ ->
          :ok
      end
    end)

    :ok
  end

  test "ensure_whatsapp_checkout_fixture!/0 creates an active event and active WhatsApp offer" do
    summary = SandboxFixtures.ensure_whatsapp_checkout_fixture!()

    event = Repo.get!(Event, summary.event_id)
    offer = get_offer!(summary.offer_id, summary.event_id)

    assert String.starts_with?(event.name, @event_name_prefix)
    assert String.starts_with?(event.shortname, @event_shortname_prefix)
    assert event.status == "active"
    assert event.total_tickets == 20
    assert event.site_url == "https://scan.voelgoed.co.za"
    assert event.tickera_site_url == "https://scan.voelgoed.co.za"
    assert event.scanner_login_code =~ ~r/^[0-9A-HJKMNP-TV-Z]{6}$/

    assert summary == %{
             event_id: event.id,
             event_name: event.name,
             scanner_login_code: event.scanner_login_code,
             offer_id: offer.id,
             offer_name: "General Admission",
             sales_channel: "whatsapp",
             configured_quantity: 20
           }

    assert offer.name == "General Admission"
    assert offer.ticket_type == "General Admission"
    assert offer.price_cents == 1_000
    assert offer.currency == "ZAR"
    assert offer.configured_quantity_available == 20
    assert offer.initial_quantity == 20
    assert offer.max_per_order == 3
    assert offer.sales_enabled == true
    assert offer.sales_channel == "whatsapp"
    assert is_nil(offer.archived_at)
    assert DateTime.compare(offer.starts_at, DateTime.utc_now()) == :lt
    assert DateTime.compare(offer.ends_at, DateTime.utc_now()) == :gt
  end

  test "ensure_whatsapp_checkout_fixture!/0 reuses the same offer when the existing fixture is safe" do
    first = SandboxFixtures.ensure_whatsapp_checkout_fixture!()
    second = SandboxFixtures.ensure_whatsapp_checkout_fixture!()

    assert second.event_id == first.event_id
    assert second.offer_id == first.offer_id

    assert 1 == active_sandbox_event_count()
    assert 1 == unarchived_sandbox_offer_count(first.event_id)

    assert {:ok, snapshot} = ReservationLedger.get_availability(first.offer_id)
    assert snapshot.configured_quantity == 20
    assert snapshot.available_quantity == 20
    assert snapshot.reserved_quantity == 0
    assert snapshot.consumed_quantity == 0
    assert snapshot.ledger_state == :healthy
  end

  test "ensure_whatsapp_checkout_fixture!/0 creates a fresh version when existing sandbox state is unsafe" do
    first = SandboxFixtures.ensure_whatsapp_checkout_fixture!()
    insert_active_order_with_line!(first.event_id, first.offer_id)

    second = SandboxFixtures.ensure_whatsapp_checkout_fixture!()

    assert second.event_id != first.event_id
    assert second.offer_id != first.offer_id

    old_event = Repo.get!(Event, first.event_id)
    old_offer = get_offer!(first.offer_id, first.event_id)

    assert old_event.status == "archived"
    assert old_offer.sales_enabled == false
    assert %DateTime{} = old_offer.archived_at

    assert {:ok, snapshot} = ReservationLedger.get_availability(second.offer_id)
    assert snapshot.available_quantity == 20
    assert snapshot.reserved_quantity == 0
    assert snapshot.consumed_quantity == 0
  end

  test "reset_whatsapp_checkout_fixture!/0 archives old sandbox records and creates a fresh fixture" do
    first = SandboxFixtures.ensure_whatsapp_checkout_fixture!()
    insert_active_order_with_line!(first.event_id, first.offer_id)

    second = SandboxFixtures.reset_whatsapp_checkout_fixture!()

    assert second.event_id != first.event_id
    assert second.offer_id != first.offer_id

    old_event = Repo.get!(Event, first.event_id)
    old_offer = get_offer!(first.offer_id, first.event_id)

    assert old_event.status == "archived"
    assert old_offer.sales_enabled == false
    assert %DateTime{} = old_offer.archived_at

    new_event = Repo.get!(Event, second.event_id)
    new_offer = get_offer!(second.offer_id, second.event_id)

    assert new_event.status == "active"
    assert new_offer.sales_enabled == true
    assert is_nil(new_offer.archived_at)
  end

  test "reset_whatsapp_checkout_fixture!/0 does not affect non-sandbox events or offers" do
    event = insert_event!(%{name: "Real Event", shortname: "Real Event"})
    offer = create_offer!(event.id, %{name: "Real General"})

    summary = SandboxFixtures.reset_whatsapp_checkout_fixture!()

    reloaded_event = Repo.get!(Event, event.id)
    reloaded_offer = get_offer!(offer.id, event.id)

    assert summary.event_id != event.id
    assert reloaded_event.status == "active"
    assert reloaded_offer.sales_enabled == true
    assert is_nil(reloaded_offer.archived_at)
  end

  test "Redis inventory is initialized for the returned sandbox offer" do
    summary = SandboxFixtures.ensure_whatsapp_checkout_fixture!()

    assert {:ok, snapshot} = ReservationLedger.get_availability(summary.offer_id)
    assert snapshot.configured_quantity == 20
    assert snapshot.available_quantity == 20
    assert snapshot.reserved_quantity == 0
    assert snapshot.consumed_quantity == 0
    assert snapshot.ledger_state == :healthy
  end

  test "created offer is visible through TicketOffer list_active_for_event for WhatsApp" do
    summary = SandboxFixtures.ensure_whatsapp_checkout_fixture!()

    offers =
      TicketOffer
      |> Query.for_read(
        :list_active_for_event,
        %{
          event_id: summary.event_id,
          sales_channel: "whatsapp",
          as_of: DateTime.utc_now()
        },
        actor: %{
          actor_type: :customer_session,
          actor_id: "sandbox-fixture-test",
          allowed_event_ids: [summary.event_id]
        }
      )
      |> Ash.read!(authorize?: true)

    assert Enum.map(offers, & &1.id) == [summary.offer_id]
  end

  test "returned and logged summaries do not expose sensitive values in logs" do
    {summary, log} =
      capture_fixture_log(fn ->
        SandboxFixtures.ensure_whatsapp_checkout_fixture!()
      end)

    assert Map.keys(summary) |> Enum.sort() ==
             [
               :configured_quantity,
               :event_id,
               :event_name,
               :offer_id,
               :offer_name,
               :sales_channel,
               :scanner_login_code
             ]
             |> Enum.sort()

    assert is_binary(summary.scanner_login_code)
    assert summary.scanner_login_code != ""

    unsafe_values = [
      @dummy_tickera_api_key,
      @dummy_mobile_secret,
      "buyer@example.com",
      "+27821234567",
      "authorization_url",
      "payment_url",
      "ticket_url",
      "delivery_token",
      summary.scanner_login_code
    ]

    Enum.each(unsafe_values, fn value ->
      refute log =~ value
    end)

    assert log =~ "scanner_login_code_present=true"
  end

  defp capture_fixture_log(fun) do
    ref = make_ref()
    previous_level = Logger.level()
    Logger.configure(level: :info)

    log =
      try do
        capture_log([level: :info], fn ->
          Process.put(ref, fun.())
        end)
      after
        Logger.configure(level: previous_level)
      end

    {Process.get(ref), log}
  end

  defp insert_event!(attrs) do
    api_key = Map.get(attrs, :tickera_api_key, "real-test-api-key")
    mobile_secret = Map.get(attrs, :mobile_secret, "real-mobile-secret")
    {:ok, encrypted_api_key} = Crypto.encrypt(api_key)
    {:ok, encrypted_mobile_secret} = Crypto.encrypt(mobile_secret)

    defaults = %{
      name: "Event #{System.unique_integer([:positive])}",
      shortname: "Event #{System.unique_integer([:positive])}",
      site_url: "https://example.com",
      tickera_site_url: "https://example.com",
      tickera_api_key_encrypted: encrypted_api_key,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      mobile_access_secret_encrypted: encrypted_mobile_secret,
      status: "active",
      total_tickets: 20,
      entrance_name: "Main"
    }

    defaults
    |> Map.merge(attrs)
    |> Map.delete(:tickera_api_key)
    |> Map.delete(:mobile_secret)
    |> then(fn params ->
      %Event{}
      |> Event.changeset(params)
      |> Repo.insert!()
    end)
  end

  defp create_offer!(event_id, overrides) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      %{
        event_id: event_id,
        name: "General Admission",
        ticket_type: "General Admission",
        price_cents: 1_000,
        currency: "ZAR",
        configured_quantity_available: 20,
        initial_quantity: 20,
        max_per_order: 3,
        sales_enabled: true,
        sales_channel: "whatsapp",
        starts_at: DateTime.add(now, -5 * 60, :second),
        ends_at: DateTime.add(now, 7 * 24 * 60 * 60, :second)
      }
      |> Map.merge(overrides)

    TicketOffer
    |> Changeset.for_create(:create_offer, attrs,
      actor: admin_actor(event_id),
      authorize?: true
    )
    |> Ash.create!(authorize?: true)
  end

  defp get_offer!(offer_id, event_id) do
    TicketOffer
    |> Query.for_read(:get_by_id, %{id: offer_id},
      actor: admin_actor(event_id),
      authorize?: true
    )
    |> Ash.read_one!(authorize?: true)
  end

  defp insert_active_order_with_line!(event_id, offer_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    public_reference = "FC-#{System.unique_integer([:positive])}"

    %{rows: [[order_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, idempotency_key, inserted_at, updated_at)
        VALUES
          ($1, $2, 'Buyer', '+27821234567', 'buyer@example.com', 'whatsapp',
           'awaiting_payment', 1000, 'ZAR', $3, $4, $4)
        RETURNING id
        """,
        [public_reference, event_id, "sandbox-#{System.unique_integer([:positive])}", now]
      )

    Repo.query!(
      """
      INSERT INTO sales_order_lines
        (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
         event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
         metadata, inserted_at, updated_at)
      VALUES
        ($1, $2, 1, 'General Admission', 'General Admission', 'Sandbox Event',
         1, 1000, 1000, 'ZAR', '{}', $3, $3)
      """,
      [order_id, offer_id, now]
    )

    Repo.query!(
      """
      INSERT INTO sales_checkout_sessions
        (sales_order_id, status, redis_hold_key, hold_quantity, expires_at, state_data,
         inserted_at, updated_at)
      VALUES
        ($1, 'hold_attached', $2, 1, $3, '{}', $4, $4)
      """,
      [
        order_id,
        "sales:hold:#{public_reference}",
        DateTime.add(now, 10 * 60, :second),
        now
      ]
    )

    order_id
  end

  defp active_sandbox_event_count do
    Repo.one!(
      from e in Event,
        where:
          like(e.name, ^"#{@event_name_prefix}%") and
            like(e.shortname, ^"#{@event_shortname_prefix}%") and e.status == "active",
        select: count(e.id)
    )
  end

  defp unarchived_sandbox_offer_count(event_id) do
    Repo.one!(
      from o in "sales_ticket_offers",
        where:
          o.event_id == ^event_id and o.name == "General Admission" and is_nil(o.archived_at),
        select: count(o.id)
    )
  end

  defp sandbox_offer_ids do
    Repo.all(
      from o in "sales_ticket_offers",
        join: e in Event,
        on: e.id == o.event_id,
        where:
          like(e.name, ^"#{@event_name_prefix}%") and
            like(e.shortname, ^"#{@event_shortname_prefix}%"),
        select: o.id
    )
  end

  defp admin_actor(event_id) do
    %{actor_type: :admin, actor_id: "sandbox-fixture-test", allowed_event_ids: [event_id]}
  end
end
