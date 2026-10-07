defmodule FastCheck.Tickets.TicketExchangeTest do
  use FastCheck.DataCase, async: false

  alias Ash.Changeset
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Fixtures
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Tickets.DeliveryToken
  alias FastCheck.Tickets.TicketExchange
  alias FastCheck.Tickets.TicketSession
  alias FastCheck.Tickets.TokenHash
  alias FastCheckWeb.SalesWebFixtures

  describe "exchange/2" do
    test "valid token with existing browser session succeeds and binds Redis" do
      %{token: token, ticket_issue_id: ticket_issue_id, delivery_hash: delivery_hash} =
        issued_ticket_fixture()

      existing_session = TicketSession.new_browser_session_id()

      assert {:ok, %{browser_session_id: returned_session, ticket_issue_id: returned_id}} =
               TicketExchange.exchange(token, browser_session_id: existing_session)

      assert returned_session == existing_session
      assert returned_id == ticket_issue_id

      assert {:ok, binding} = TicketSession.fetch_binding(existing_session, ticket_issue_id)
      assert binding.generation == 0
      assert binding.fingerprint == TicketSession.generation_fingerprint(delivery_hash)

      ttl = redis_ttl!(existing_session)
      assert ttl in 86_300..86_400

      inspected = inspect(%{browser_session_id: returned_session, ticket_issue_id: returned_id})
      refute inspected =~ token
      refute inspected =~ delivery_hash
    end

    test "valid token without browser session creates opaque id and minimal success map" do
      %{token: token, ticket_issue_id: ticket_issue_id} = issued_ticket_fixture()

      assert {:ok, result} = TicketExchange.exchange(token)
      assert Map.keys(result) |> Enum.sort() == [:browser_session_id, :ticket_issue_id]
      assert result.ticket_issue_id == ticket_issue_id
      assert byte_size(Base.url_decode64!(result.browser_session_id, padding: false)) == 32

      assert {:ok, _} = TicketSession.fetch_binding(result.browser_session_id, ticket_issue_id)
    end

    test "invalid bearer is denied without Redis bind" do
      session = TicketSession.new_browser_session_id()

      assert {:error, :invalid_token} =
               TicketExchange.exchange("not-a-valid-token-at-all", browser_session_id: session)

      refute redis_key_exists?(session)
    end

    test "expired bearer is denied without Redis bind" do
      %{token: token} =
        issued_ticket_fixture(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))

      session = TicketSession.new_browser_session_id()

      assert {:error, :expired_token} =
               TicketExchange.exchange(token, browser_session_id: session)

      refute redis_key_exists?(session)
    end

    test "revoked bearer is denied without Redis bind" do
      %{token: token} =
        issued_ticket_fixture(status: "revoked", revoked_at: DateTime.utc_now())

      session = TicketSession.new_browser_session_id()

      assert {:error, :revoked_token} =
               TicketExchange.exchange(token, browser_session_id: session)

      refute redis_key_exists?(session)
    end

    test "not-ready ticket is denied before Redis bind" do
      %{token: token, ticket_issue_id: ticket_issue_id} = issued_ticket_fixture(status: "pending")
      session = TicketSession.new_browser_session_id()

      assert {:error, :not_ready} =
               TicketExchange.exchange(token, browser_session_id: session)

      refute redis_key_exists?(session)
      assert {:error, :not_found} = TicketSession.fetch_binding(session, ticket_issue_id)
    end

    test "not-scannable attendee is denied before Redis bind" do
      %{token: token, ticket_issue_id: ticket_issue_id, attendee: attendee} =
        issued_ticket_fixture()

      attendee
      |> Attendee.changeset(%{scan_eligibility: "not_scannable"})
      |> Repo.update!()

      session = TicketSession.new_browser_session_id()

      assert {:error, :not_scannable} =
               TicketExchange.exchange(token, browser_session_id: session)

      refute redis_key_exists?(session)
      assert {:error, :not_found} = TicketSession.fetch_binding(session, ticket_issue_id)
    end

    test "redis unavailable fails closed without fallback" do
      %{token: token} = issued_ticket_fixture()
      session = TicketSession.new_browser_session_id()

      assert {:error, :session_unavailable} =
               TicketExchange.exchange(token,
                 browser_session_id: session,
                 redix_name: :ticket_exchange_missing_redix
               )

      refute redis_key_exists?(session)
    end

    test "stale generation token is denied and does not replace newer Redis generation" do
      %{token: stale_token, ticket_issue_id: ticket_issue_id} = issued_ticket_fixture()
      issue = Ash.get!(TicketIssue, ticket_issue_id, authorize?: false)

      %{hash: rotated_hash} =
        DeliveryToken.generate(
          now: DateTime.utc_now() |> DateTime.truncate(:second),
          ttl_seconds: 3600
        )

      expires_at = DateTime.utc_now() |> DateTime.add(7200, :second) |> DateTime.truncate(:second)

      assert {:ok, rotated} =
               issue
               |> Changeset.for_update(
                 :rotate_delivery_token_for_delivery,
                 %{delivery_token_hash: rotated_hash, delivery_token_expires_at: expires_at},
                 actor: system_actor()
               )
               |> Ash.update(authorize?: false)

      assert rotated.delivery_token_generation == 1

      session = TicketSession.new_browser_session_id()

      assert {:error, :invalid_token} =
               TicketExchange.exchange(stale_token, browser_session_id: session)

      refute redis_key_exists?(session)

      fp2 = TicketSession.generation_fingerprint(rotated_hash)

      assert {:ok, :bound} =
               TicketSession.bind(
                 session,
                 ticket_issue_id,
                 1,
                 fp2,
                 TicketSession.session_idle_ttl_seconds()
               )

      assert {:error, :stale_generation} =
               TicketSession.bind(
                 session,
                 ticket_issue_id,
                 0,
                 TicketSession.generation_fingerprint(issue.delivery_token_hash),
                 TicketSession.session_idle_ttl_seconds()
               )

      assert {:ok, %{generation: 1}} = TicketSession.fetch_binding(session, ticket_issue_id)
    end

    test "post-bind durable rotation denies exchange and removes stale binding" do
      %{token: token, ticket_issue_id: ticket_issue_id, delivery_hash: delivery_hash} =
        issued_ticket_fixture()

      session = TicketSession.new_browser_session_id()
      stale_fp = TicketSession.generation_fingerprint(delivery_hash)
      stale_encoded = "v1:0:#{stale_fp}"

      assert {:error, :denied} =
               TicketExchange.exchange(token,
                 browser_session_id: session,
                 after_bind: fn ->
                   rotate_issue!(ticket_issue_id)
                 end
               )

      assert {:error, :not_found} = TicketSession.fetch_binding(session, ticket_issue_id)

      refute redis_hget(session, ticket_issue_id) == stale_encoded
    end

    test "stale post-bind cleanup cannot remove concurrent G2 binding" do
      %{token: token, ticket_issue_id: ticket_issue_id, delivery_hash: delivery_hash} =
        issued_ticket_fixture()

      session = TicketSession.new_browser_session_id()
      stale_fp = TicketSession.generation_fingerprint(delivery_hash)

      %{hash: rotated_hash} =
        DeliveryToken.generate(
          now: DateTime.utc_now() |> DateTime.truncate(:second),
          ttl_seconds: 3600
        )

      rotated_fp = TicketSession.generation_fingerprint(rotated_hash)

      assert {:error, :denied} =
               TicketExchange.exchange(token,
                 browser_session_id: session,
                 after_bind: fn ->
                   rotate_issue_with_hash!(ticket_issue_id, rotated_hash)

                   assert {:ok, :bound} =
                            TicketSession.bind(
                              session,
                              ticket_issue_id,
                              1,
                              rotated_fp,
                              TicketSession.session_idle_ttl_seconds()
                            )
                 end
               )

      assert {:ok, %{generation: 1, fingerprint: ^rotated_fp}} =
               TicketSession.fetch_binding(session, ticket_issue_id)

      refute TicketSession.generation_fingerprint(delivery_hash) == rotated_fp

      assert {:ok, :not_removed} =
               TicketSession.conditional_remove(session, ticket_issue_id, "v1:0:#{stale_fp}")
    end
  end

  defp issued_ticket_fixture(opts \\ []) do
    event = Fixtures.create_event()
    SalesWebFixtures.configure_dashboard_grants([event.id])
    attendee = Fixtures.create_attendee(event, %{payment_status: "completed"})
    ticket_code = attendee.ticket_code

    %{token: token, hash: delivery_hash, expires_at: expires_at} =
      DeliveryToken.generate(
        now: Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second)),
        ttl_seconds: Keyword.get(opts, :ttl_seconds, 3600)
      )

    expires_at = Keyword.get(opts, :expires_at, expires_at)
    status = Keyword.get(opts, :status, "issued")
    revoked_at = Keyword.get(opts, :revoked_at)
    qr_hash = TokenHash.hash("qr-#{System.unique_integer([:positive])}", :qr)

    {order_id, order_line_id} = insert_order_with_line!(event.id)

    attrs = %{
      sales_order_id: order_id,
      sales_order_line_id: order_line_id,
      line_item_sequence: 1,
      attendee_id: attendee.id,
      ticket_code: ticket_code,
      qr_token_hash: qr_hash,
      delivery_token_hash: delivery_hash,
      delivery_token_expires_at: expires_at
    }

    assert {:ok, ticket_issue} =
             TicketIssue
             |> Changeset.for_create(:create_issued_link, attrs, actor: system_actor())
             |> Ash.create(authorize?: false)

    if status != "issued" or not is_nil(revoked_at) do
      Repo.query!(
        "UPDATE sales_ticket_issues SET status = $1, revoked_at = $2 WHERE id = $3",
        [status, revoked_at, ticket_issue.id]
      )
    end

    attendee =
      attendee
      |> Attendee.changeset(%{sales_ticket_issue_id: ticket_issue.id})
      |> Repo.update!()

    %{
      token: token,
      delivery_hash: delivery_hash,
      ticket_issue_id: ticket_issue.id,
      attendee: attendee,
      event: event
    }
  end

  defp rotate_issue!(ticket_issue_id) do
    %{hash: hash, expires_at: expires_at} =
      DeliveryToken.generate(
        now: DateTime.utc_now() |> DateTime.truncate(:second),
        ttl_seconds: 3600
      )

    rotate_issue_with_hash!(ticket_issue_id, hash, expires_at)
  end

  defp rotate_issue_with_hash!(ticket_issue_id, hash, expires_at \\ nil) do
    expires_at =
      expires_at ||
        DateTime.utc_now() |> DateTime.add(7200, :second) |> DateTime.truncate(:second)

    issue = Ash.get!(TicketIssue, ticket_issue_id, authorize?: false)

    assert {:ok, _} =
             issue
             |> Changeset.for_update(
               :rotate_delivery_token_for_delivery,
               %{delivery_token_hash: hash, delivery_token_expires_at: expires_at},
               actor: system_actor()
             )
             |> Ash.update(authorize?: false)
  end

  defp insert_order_with_line!(event_id) do
    offer_id =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
           lock_version, inserted_at, updated_at)
        VALUES
          ($1, $2, 'general', 100, 'ZAR', 10, 10, 5, true, 'whatsapp',
           now(), now() + interval '1 day', 1, now(), now())
        RETURNING id
        """,
        [event_id, "Exchange Offer #{System.unique_integer([:positive])}"]
      )
      |> Map.fetch!(:rows)
      |> List.first()
      |> List.first()

    order_id =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, source_channel, status, total_amount_cents,
           currency, inserted_at, updated_at)
        VALUES
          ($1, $2, 'Buyer', 'whatsapp', 'ticket_issued', 100, 'ZAR', now(), now())
        RETURNING id
        """,
        ["FC-EX-#{System.unique_integer([:positive])}", event_id]
      )
      |> Map.fetch!(:rows)
      |> List.first()
      |> List.first()

    order_line_id =
      Repo.query!(
        """
        INSERT INTO sales_order_lines
          (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
           event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
           metadata, inserted_at, updated_at)
        VALUES
          ($1, $2, 1, 'general', 'Offer', 'Event', 1, 100, 100, 'ZAR', '{}', now(), now())
        RETURNING id
        """,
        [order_id, offer_id]
      )
      |> Map.fetch!(:rows)
      |> List.first()
      |> List.first()

    {order_id, order_line_id}
  end

  defp redis_ttl!(browser_session_id) do
    key = TicketSession.registry_key(browser_session_id)
    {:ok, ttl} = Redix.command(FastCheck.Redix, ["TTL", key])
    ttl
  end

  defp redis_key_exists?(browser_session_id) do
    key = TicketSession.registry_key(browser_session_id)

    case Redix.command(FastCheck.Redix, ["EXISTS", key]) do
      {:ok, 1} -> true
      _ -> false
    end
  end

  defp redis_hget(browser_session_id, ticket_issue_id) do
    key = TicketSession.registry_key(browser_session_id)
    field = "ticket:#{ticket_issue_id}"

    case Redix.command(FastCheck.Redix, ["HGET", key, field]) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp system_actor, do: %{actor_type: :system, actor_id: "ticket_exchange_test"}
end
