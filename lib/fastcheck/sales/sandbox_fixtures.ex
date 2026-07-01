defmodule FastCheck.Sales.SandboxFixtures do
  @moduledoc """
  Operator/devops-only runtime fixtures for WhatsApp checkout sandbox testing.

  This module is intentionally release-callable and has no public UI surface.
  It creates and resets only records that are clearly owned by this sandbox
  fixture, identified by both the event name and shortname prefixes.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Crypto
  alias FastCheck.Events.Cache
  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.TicketOffer

  @event_name_prefix "WhatsApp Sandbox Test Event"
  @event_shortname_prefix "WA Sandbox"
  @offer_name "General Admission"
  @ticket_type "General Admission"
  @price_cents 1_000
  @currency "ZAR"
  @quantity 20
  @max_per_order 3
  @sales_channel "whatsapp"
  @default_site_url "https://scan.voelgoed.co.za"
  @dummy_tickera_api_key "whatsapp-sandbox-dummy-tickera-api-key"
  @dummy_mobile_secret "whatsapp-sandbox-dummy-mobile-secret"
  @terminal_order_statuses ["cancelled", "expired", "refunded"]
  @terminal_checkout_statuses ["expired", "released", "failed"]
  @scanner_code_alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @scanner_code_length 6
  @scanner_code_space 1_073_741_824
  @sandbox_scanner_code_max_attempts 8

  @type summary :: %{
          event_id: pos_integer(),
          event_name: String.t(),
          scanner_login_code: String.t(),
          offer_id: pos_integer(),
          offer_name: String.t(),
          sales_channel: String.t(),
          configured_quantity: pos_integer()
        }

  @doc """
  Ensures a reusable WhatsApp checkout sandbox fixture exists.

  Existing sandbox offers are reused only when there is no active durable order,
  checkout session, Redis hold, consumed inventory, or uncertain Redis state.
  Otherwise, a fresh sandbox event/offer version is created.
  """
  @spec ensure_whatsapp_checkout_fixture!() :: summary()
  def ensure_whatsapp_checkout_fixture! do
    now = current_time()

    sandbox_events()
    |> Enum.find(&(&1.status == "active"))
    |> case do
      %Event{} = event ->
        ensure_for_existing_event(event, now)

      nil ->
        create_fresh_fixture!(now)
    end
    |> log_safe_summary()
  end

  @doc """
  Archives old sandbox-owned records and creates a fresh WhatsApp checkout fixture.
  """
  @spec reset_whatsapp_checkout_fixture!() :: summary()
  def reset_whatsapp_checkout_fixture! do
    now = current_time()

    archive_sandbox_records!(now)

    now
    |> create_fresh_fixture!()
    |> log_safe_summary()
  end

  defp ensure_for_existing_event(%Event{} = event, now) do
    case unarchived_offer_for_event(event.id) do
      nil ->
        event
        |> update_event!(now)
        |> create_fixture_offer!(now)
        |> initialize_and_summarize!()

      %TicketOffer{} = offer ->
        if reusable_offer?(offer) do
          event = update_event!(event, now)
          offer = update_offer!(offer, now)
          offer = ensure_offer_enabled!(offer)

          initialize_and_summarize!({event, offer})
        else
          archive_sandbox_records!(now)
          create_fresh_fixture!(now)
        end
    end
  end

  defp create_fresh_fixture!(now) do
    now
    |> create_event!()
    |> create_fixture_offer!(now)
    |> initialize_and_summarize!()
  end

  defp create_event!(now) do
    site_url = sandbox_site_url()
    suffix = fixture_suffix(now)
    {:ok, encrypted_api_key} = Crypto.encrypt(@dummy_tickera_api_key)
    {:ok, encrypted_mobile_secret} = Crypto.encrypt(@dummy_mobile_secret)
    {starts_at, ends_at} = window(now)

    event =
      insert_sandbox_event_with_retry!(
        %{
          name: "#{@event_name_prefix} #{suffix}",
          shortname: "#{@event_shortname_prefix} #{suffix}",
          site_url: site_url,
          tickera_site_url: site_url,
          tickera_api_key_encrypted: encrypted_api_key,
          tickera_api_key_last4: String.slice(@dummy_tickera_api_key, -4, 4),
          mobile_access_secret_encrypted: encrypted_mobile_secret,
          scanner_login_code: sandbox_scanner_login_code(suffix),
          status: "active",
          total_tickets: @quantity,
          tickera_start_date: starts_at,
          tickera_end_date: ends_at,
          entrance_name: "Main"
        },
        suffix,
        0
      )

    persist_active_event!(event)
  end

  defp insert_sandbox_event_with_retry!(attrs, suffix, attempt)
       when attempt < @sandbox_scanner_code_max_attempts do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, event} ->
        event

      {:error, %Ecto.Changeset{} = changeset} ->
        if scanner_login_code_conflict?(changeset) do
          attrs =
            Map.put(
              attrs,
              :scanner_login_code,
              sandbox_scanner_login_code("#{suffix}-#{attempt + 1}")
            )

          insert_sandbox_event_with_retry!(attrs, suffix, attempt + 1)
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp insert_sandbox_event_with_retry!(attrs, _suffix, _attempt) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert!()
  end

  defp scanner_login_code_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:scanner_login_code, {_message, opts}} ->
        opts[:constraint] == :unique or opts[:constraint_name] == "idx_events_scanner_login_code"

      _error ->
        false
    end)
  end

  defp sandbox_scanner_login_code(seed) when is_binary(seed) do
    seed
    |> :erlang.phash2(@scanner_code_space)
    |> encode_scanner_code([])
    |> IO.iodata_to_binary()
    |> String.pad_leading(@scanner_code_length, "0")
  end

  defp encode_scanner_code(value, acc) when value < 32 do
    [<<Enum.at(@scanner_code_alphabet, value)>> | acc]
  end

  defp encode_scanner_code(value, acc) do
    remainder = rem(value, 32)
    quotient = div(value, 32)

    encode_scanner_code(quotient, [<<Enum.at(@scanner_code_alphabet, remainder)>> | acc])
  end

  defp update_event!(%Event{} = event, now) do
    site_url = sandbox_site_url()
    {:ok, encrypted_api_key} = Crypto.encrypt(@dummy_tickera_api_key)
    {:ok, encrypted_mobile_secret} = Crypto.encrypt(@dummy_mobile_secret)
    {starts_at, ends_at} = window(now)

    event =
      event
      |> Event.changeset(%{
        site_url: site_url,
        tickera_site_url: site_url,
        tickera_api_key_encrypted: encrypted_api_key,
        tickera_api_key_last4: String.slice(@dummy_tickera_api_key, -4, 4),
        mobile_access_secret_encrypted: encrypted_mobile_secret,
        status: "active",
        total_tickets: @quantity,
        tickera_start_date: starts_at,
        tickera_end_date: ends_at,
        entrance_name: "Main"
      })
      |> Repo.update!()

    persist_active_event!(event)
  end

  defp archive_event!(%Event{} = event) do
    event =
      event
      |> Event.changeset(%{status: "archived"})
      |> Repo.update!()

    Cache.invalidate_event_cache(event.id)
    Cache.invalidate_events_list_cache()

    event
  end

  defp create_fixture_offer!(%Event{} = event, now) do
    {starts_at, ends_at} = window(now)

    offer =
      TicketOffer
      |> Changeset.for_create(
        :create_offer,
        %{
          event_id: event.id,
          name: @offer_name,
          ticket_type: @ticket_type,
          price_cents: @price_cents,
          currency: @currency,
          configured_quantity_available: @quantity,
          initial_quantity: @quantity,
          max_per_order: @max_per_order,
          sales_enabled: true,
          sales_channel: @sales_channel,
          starts_at: starts_at,
          ends_at: ends_at
        },
        actor: admin_actor(event.id),
        authorize?: true
      )
      |> Ash.create!(authorize?: true)

    {event, offer}
  end

  defp update_offer!(%TicketOffer{} = offer, now) do
    {starts_at, ends_at} = window(now)

    offer
    |> Changeset.for_update(
      :update_offer,
      %{
        name: @offer_name,
        ticket_type: @ticket_type,
        price_cents: @price_cents,
        currency: @currency,
        configured_quantity_available: @quantity,
        initial_quantity: @quantity,
        max_per_order: @max_per_order,
        sales_channel: @sales_channel,
        starts_at: starts_at,
        ends_at: ends_at
      },
      actor: admin_actor(offer.event_id),
      authorize?: true
    )
    |> Ash.update!(authorize?: true)
  end

  defp ensure_offer_enabled!(%TicketOffer{sales_enabled: true} = offer), do: offer

  defp ensure_offer_enabled!(%TicketOffer{} = offer) do
    offer
    |> Changeset.for_update(:enable_sales, %{},
      actor: admin_actor(offer.event_id),
      authorize?: true
    )
    |> Ash.update!(authorize?: true)
  end

  defp disable_offer!(%TicketOffer{sales_enabled: false} = offer), do: offer

  defp disable_offer!(%TicketOffer{} = offer) do
    offer
    |> Changeset.for_update(:disable_sales, %{},
      actor: admin_actor(offer.event_id),
      authorize?: true
    )
    |> Ash.update!(authorize?: true)
  end

  defp archive_offer!(%TicketOffer{} = offer, now) do
    offer
    |> disable_offer!()
    |> Changeset.for_update(:update_offer, %{archived_at: now},
      actor: admin_actor(offer.event_id),
      authorize?: true
    )
    |> Ash.update!(authorize?: true)
  end

  defp archive_sandbox_records!(now) do
    sandbox_events()
    |> Enum.each(fn event ->
      event.id
      |> unarchived_offers_for_event()
      |> Enum.each(&archive_offer!(&1, now))

      if event.status != "archived" do
        archive_event!(event)
      else
        Cache.invalidate_event_cache(event.id)
        Cache.invalidate_events_list_cache()
      end
    end)
  end

  defp initialize_and_summarize!({%Event{} = event, %TicketOffer{} = offer}) do
    :ok = ReservationLedger.initialize_offer(offer.id, @quantity)

    %{
      event_id: event.id,
      event_name: event.name,
      scanner_login_code: event.scanner_login_code,
      offer_id: offer.id,
      offer_name: offer.name,
      sales_channel: offer.sales_channel,
      configured_quantity: offer.configured_quantity_available
    }
  end

  defp reusable_offer?(%TicketOffer{} = offer) do
    not active_order_exists?(offer) and
      not active_checkout_session_exists?(offer) and
      redis_inventory_reusable?(offer.id)
  end

  defp active_order_exists?(%TicketOffer{} = offer) do
    Repo.exists?(
      from o in "sales_orders",
        join: l in "sales_order_lines",
        on: l.sales_order_id == o.id,
        where:
          o.event_id == ^offer.event_id and l.ticket_offer_id == ^offer.id and
            o.status not in ^@terminal_order_statuses
    )
  end

  defp active_checkout_session_exists?(%TicketOffer{} = offer) do
    Repo.exists?(
      from cs in "sales_checkout_sessions",
        join: o in "sales_orders",
        on: o.id == cs.sales_order_id,
        join: l in "sales_order_lines",
        on: l.sales_order_id == o.id,
        where:
          o.event_id == ^offer.event_id and l.ticket_offer_id == ^offer.id and
            o.status not in ^@terminal_order_statuses and
            cs.status not in ^@terminal_checkout_statuses
    )
  end

  defp redis_inventory_reusable?(offer_id) do
    case ReservationLedger.get_availability(offer_id) do
      {:ok,
       %{
         ledger_state: :healthy,
         reserved_quantity: 0,
         consumed_quantity: 0
       }} ->
        true

      _ ->
        false
    end
  end

  defp sandbox_events do
    Repo.all(
      from e in Event,
        where:
          like(e.name, ^"#{@event_name_prefix}%") and
            like(e.shortname, ^"#{@event_shortname_prefix}%"),
        order_by: [desc: e.id]
    )
  end

  defp unarchived_offer_for_event(event_id) do
    event_id
    |> unarchived_offers_for_event()
    |> List.first()
  end

  defp unarchived_offers_for_event(event_id) do
    ids =
      Repo.all(
        from o in "sales_ticket_offers",
          where: o.event_id == ^event_id and o.name == ^@offer_name and is_nil(o.archived_at),
          order_by: [desc: o.id],
          select: o.id
      )

    Enum.map(ids, &get_offer!(&1, event_id))
  end

  defp get_offer!(offer_id, event_id) do
    TicketOffer
    |> Query.for_read(:get_by_id, %{id: offer_id}, actor: admin_actor(event_id), authorize?: true)
    |> Ash.read_one!(authorize?: true)
  end

  defp persist_active_event!(%Event{} = event) do
    Cache.persist_event_cache(event)
    Cache.invalidate_events_list_cache()
    event
  end

  defp sandbox_site_url do
    configured =
      :fastcheck
      |> Application.get_env(:whatsapp_checkout_sandbox_site_url)
      |> present_string()

    configured || endpoint_site_url() || @default_site_url
  end

  defp endpoint_site_url do
    if Code.ensure_loaded?(FastCheckWeb.Endpoint) do
      FastCheckWeb.Endpoint.config(:url)
      |> endpoint_url_to_string()
      |> case do
        nil -> nil
        url -> reject_localhost(url)
      end
    end
  end

  defp endpoint_url_to_string(url_config) when is_list(url_config) do
    host = url_config |> Keyword.get(:host) |> present_string()
    scheme = url_config |> Keyword.get(:scheme, "https") |> to_string()
    port = Keyword.get(url_config, :port)

    if host do
      case {scheme, port} do
        {"https", port} when port in [nil, 443] -> "https://#{host}"
        {"http", port} when port in [nil, 80] -> "http://#{host}"
        {scheme, nil} -> "#{scheme}://#{host}"
        {scheme, port} -> "#{scheme}://#{host}:#{port}"
      end
    end
  end

  defp endpoint_url_to_string(_url_config), do: nil

  defp reject_localhost("https://localhost" <> _rest), do: nil
  defp reject_localhost("http://localhost" <> _rest), do: nil
  defp reject_localhost("https://127.0.0.1" <> _rest), do: nil
  defp reject_localhost("http://127.0.0.1" <> _rest), do: nil
  defp reject_localhost("http://" <> _rest), do: nil
  defp reject_localhost(url), do: url

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_value), do: nil

  defp window(now) do
    {
      DateTime.add(now, -5 * 60, :second),
      DateTime.add(now, 7 * 24 * 60 * 60, :second)
    }
  end

  defp current_time, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp fixture_suffix(now) do
    unique =
      System.unique_integer([:positive, :monotonic])
      |> rem(1_000_000)
      |> Integer.to_string()

    "#{DateTime.to_unix(now)}-#{unique}"
  end

  defp admin_actor(event_id) do
    %{actor_type: :admin, actor_id: "whatsapp-sandbox-fixture", allowed_event_ids: [event_id]}
  end

  defp log_safe_summary(summary) do
    Logger.info(fn ->
      "whatsapp checkout sandbox fixture ready " <>
        "event_id=#{summary.event_id} " <>
        "event_name=#{summary.event_name} " <>
        "scanner_login_code_present=#{present?(summary.scanner_login_code)} " <>
        "offer_id=#{summary.offer_id} " <>
        "offer_name=#{summary.offer_name} " <>
        "sales_channel=#{summary.sales_channel} " <>
        "configured_quantity=#{summary.configured_quantity}"
    end)

    summary
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
