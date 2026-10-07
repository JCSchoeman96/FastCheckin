defmodule FastCheck.Tickets.TicketSessionReaderTest do
  use FastCheck.DataCase, async: false

  alias Ash.Changeset
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event
  alias FastCheck.Fixtures
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Tickets.Artifact
  alias FastCheck.Tickets.DeliveryToken
  alias FastCheck.Tickets.TicketSession
  alias FastCheck.Tickets.TicketSessionReader
  alias FastCheck.Tickets.TokenHash
  alias FastCheckWeb.SalesWebFixtures

  describe "resolve/3" do
    test "valid session with matching Redis and DB returns artifact and refreshes TTL" do
      %{ticket_issue_id: ticket_issue_id, delivery_hash: delivery_hash} = issued_ticket_fixture()
      session = TicketSession.new_browser_session_id()
      fp = TicketSession.generation_fingerprint(delivery_hash)

      assert {:ok, :bound} =
               TicketSession.bind(
                 session,
                 ticket_issue_id,
                 0,
                 fp,
                 TicketSession.session_idle_ttl_seconds()
               )

      Redix.command!(FastCheck.Redix, [
        "EXPIRE",
        TicketSession.registry_key(session),
        60
      ])

      assert {:ok, %Artifact{state: :valid}} =
               TicketSessionReader.resolve(session, ticket_issue_id)

      ttl = redis_ttl!(session)
      assert ttl in 86_300..86_400
    end

    test "ticket issue id without Redis binding does not authorize" do
      %{ticket_issue_id: ticket_issue_id} = issued_ticket_fixture()
      session = TicketSession.new_browser_session_id()

      assert {:error, :not_found} = TicketSessionReader.resolve(session, ticket_issue_id)
      refute redis_key_exists?(session)
    end

    test "cross-ticket isolation" do
      fixture_a = issued_ticket_fixture()
      fixture_b = issued_ticket_fixture()

      session = TicketSession.new_browser_session_id()

      fp_a = TicketSession.generation_fingerprint(fixture_a.delivery_hash)

      assert {:ok, :bound} =
               TicketSession.bind(
                 session,
                 fixture_a.ticket_issue_id,
                 0,
                 fp_a,
                 TicketSession.session_idle_ttl_seconds()
               )

      assert {:error, :not_found} =
               TicketSessionReader.resolve(session, fixture_b.ticket_issue_id)

      fp_b = TicketSession.generation_fingerprint(fixture_b.delivery_hash)

      assert {:ok, :bound} =
               TicketSession.bind(
                 session,
                 fixture_b.ticket_issue_id,
                 0,
                 fp_b,
                 TicketSession.session_idle_ttl_seconds()
               )

      assert {:ok, %Artifact{}} =
               TicketSessionReader.resolve(session, fixture_a.ticket_issue_id)

      assert {:ok, %Artifact{}} =
               TicketSessionReader.resolve(session, fixture_b.ticket_issue_id)
    end

    test "missing Redis session key denies without reconstruction" do
      %{ticket_issue_id: ticket_issue_id, delivery_hash: delivery_hash} = issued_ticket_fixture()
      session = TicketSession.new_browser_session_id()
      fp = TicketSession.generation_fingerprint(delivery_hash)

      assert {:ok, :bound} =
               TicketSession.bind(
                 session,
                 ticket_issue_id,
                 0,
                 fp,
                 TicketSession.session_idle_ttl_seconds()
               )

      Redix.command!(FastCheck.Redix, ["DEL", TicketSession.registry_key(session)])

      assert {:error, :not_found} = TicketSessionReader.resolve(session, ticket_issue_id)
      refute redis_key_exists?(session)
    end

    test "redis unavailable fails closed" do
      %{ticket_issue_id: ticket_issue_id} = issued_ticket_fixture()
      session = TicketSession.new_browser_session_id()

      assert {:error, :session_unavailable} =
               TicketSessionReader.resolve(session, ticket_issue_id,
                 redix_name: :ticket_session_reader_missing_redix
               )
    end

    test "malformed Redis binding denies without TTL refresh or DB artifact" do
      %{ticket_issue_id: ticket_issue_id} = issued_ticket_fixture()
      session = TicketSession.new_browser_session_id()
      key = TicketSession.registry_key(session)

      Redix.command!(FastCheck.Redix, [
        "HSET",
        key,
        "ticket:#{ticket_issue_id}",
        "not-a-valid-binding"
      ])

      Redix.command!(FastCheck.Redix, ["EXPIRE", key, 30])

      assert {:error, :not_found} = TicketSessionReader.resolve(session, ticket_issue_id)
      assert redis_ttl!(session) in 25..35
    end

    test "generation mismatch denies and compare-deletes stale binding" do
      %{ticket_issue_id: ticket_issue_id, delivery_hash: delivery_hash} = issued_ticket_fixture()
      session = TicketSession.new_browser_session_id()
      stale_fp = TicketSession.generation_fingerprint(delivery_hash)
      stale_encoded = "v1:0:#{stale_fp}"

      assert {:ok, :bound} =
               TicketSession.bind(
                 session,
                 ticket_issue_id,
                 0,
                 stale_fp,
                 TicketSession.session_idle_ttl_seconds()
               )

      rotate_issue!(ticket_issue_id)

      assert {:error, :not_found} = TicketSessionReader.resolve(session, ticket_issue_id)
      refute redis_hget(session, ticket_issue_id) == stale_encoded
      assert {:error, :not_found} = TicketSession.fetch_binding(session, ticket_issue_id)
    end

    test "fingerprint mismatch denies and compare-deletes observed binding" do
      %{ticket_issue_id: ticket_issue_id, delivery_hash: delivery_hash} = issued_ticket_fixture()
      session = TicketSession.new_browser_session_id()
      current_fp = TicketSession.generation_fingerprint(delivery_hash)

      wrong_fp =
        TicketSession.generation_fingerprint("different-delivery-hash-#{System.unique_integer()}")

      assert wrong_fp != current_fp

      assert {:ok, :bound} =
               TicketSession.bind(
                 session,
                 ticket_issue_id,
                 0,
                 wrong_fp,
                 TicketSession.session_idle_ttl_seconds()
               )

      wrong_encoded = "v1:0:#{wrong_fp}"

      assert {:error, :not_found} = TicketSessionReader.resolve(session, ticket_issue_id)

      assert {:error, :not_found} = TicketSession.fetch_binding(session, ticket_issue_id)
      refute redis_hget(session, ticket_issue_id) == wrong_encoded
    end

    test "expired delivery context denies and removes binding" do
      %{ticket_issue_id: ticket_issue_id, delivery_hash: delivery_hash} =
        issued_ticket_fixture(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))

      session = TicketSession.new_browser_session_id()
      fp = TicketSession.generation_fingerprint(delivery_hash)
      encoded = "v1:0:#{fp}"

      assert {:ok, :bound} =
               TicketSession.bind(
                 session,
                 ticket_issue_id,
                 0,
                 fp,
                 TicketSession.session_idle_ttl_seconds()
               )

      assert {:error, :expired_link} = TicketSessionReader.resolve(session, ticket_issue_id)
      refute redis_hget(session, ticket_issue_id) == encoded
    end

    test "revoked ticket denies and removes binding" do
      %{ticket_issue_id: ticket_issue_id, delivery_hash: delivery_hash} =
        issued_ticket_fixture(status: "revoked", revoked_at: DateTime.utc_now())

      session = TicketSession.new_browser_session_id()
      fp = TicketSession.generation_fingerprint(delivery_hash)

      assert {:ok, :bound} =
               TicketSession.bind(
                 session,
                 ticket_issue_id,
                 0,
                 fp,
                 TicketSession.session_idle_ttl_seconds()
               )

      assert {:error, :ticket_revoked} = TicketSessionReader.resolve(session, ticket_issue_id)
      assert {:error, :not_found} = TicketSession.fetch_binding(session, ticket_issue_id)
    end

    test "artifact terminal not scannable denies and removes binding without TTL refresh" do
      %{ticket_issue_id: ticket_issue_id, delivery_hash: delivery_hash, attendee: attendee} =
        issued_ticket_fixture()

      attendee
      |> Attendee.changeset(%{scan_eligibility: "not_scannable"})
      |> Repo.update!()

      session = TicketSession.new_browser_session_id()
      fp = TicketSession.generation_fingerprint(delivery_hash)

      assert {:ok, :bound} =
               TicketSession.bind(
                 session,
                 ticket_issue_id,
                 0,
                 fp,
                 TicketSession.session_idle_ttl_seconds()
               )

      Redix.command!(FastCheck.Redix, [
        "EXPIRE",
        TicketSession.registry_key(session),
        45
      ])

      assert {:error, :ticket_not_scannable} =
               TicketSessionReader.resolve(session, ticket_issue_id)

      assert {:error, :not_found} = TicketSession.fetch_binding(session, ticket_issue_id)
      assert redis_ttl!(session) in 40..50
    end

    test "artifact terminal not ready denies and removes binding" do
      %{ticket_issue_id: ticket_issue_id, delivery_hash: delivery_hash} =
        issued_ticket_fixture(status: "pending")

      session = TicketSession.new_browser_session_id()
      fp = TicketSession.generation_fingerprint(delivery_hash)

      assert {:ok, :bound} =
               TicketSession.bind(
                 session,
                 ticket_issue_id,
                 0,
                 fp,
                 TicketSession.session_idle_ttl_seconds()
               )

      assert {:error, :ticket_not_ready} = TicketSessionReader.resolve(session, ticket_issue_id)
      assert {:error, :not_found} = TicketSession.fetch_binding(session, ticket_issue_id)
    end

    test "invalid input returns not_found without DB lookup side effects" do
      assert {:error, :not_found} = TicketSessionReader.resolve("", 1)
      assert {:error, :not_found} = TicketSessionReader.resolve("session", 0)
      assert {:error, :not_found} = TicketSessionReader.resolve("session", -1)
    end

    test "rotation race denies G1 artifact and preserves concurrent G2 binding" do
      %{ticket_issue_id: ticket_issue_id, delivery_hash: delivery_hash} = issued_ticket_fixture()
      session = TicketSession.new_browser_session_id()
      stale_fp = TicketSession.generation_fingerprint(delivery_hash)
      stale_encoded = "v1:0:#{stale_fp}"

      assert {:ok, :bound} =
               TicketSession.bind(
                 session,
                 ticket_issue_id,
                 0,
                 stale_fp,
                 TicketSession.session_idle_ttl_seconds()
               )

      %{hash: rotated_hash} =
        DeliveryToken.generate(
          now: DateTime.utc_now() |> DateTime.truncate(:second),
          ttl_seconds: 3600
        )

      rotated_fp = TicketSession.generation_fingerprint(rotated_hash)

      assert {:error, :not_found} =
               TicketSessionReader.resolve(session, ticket_issue_id,
                 after_artifact: fn ->
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

      assert {:ok, :not_removed} =
               TicketSession.conditional_remove(session, ticket_issue_id, stale_encoded)
    end

    test "rotation without fresh Redis exchange denies and removes stale G1 binding" do
      %{ticket_issue_id: ticket_issue_id, delivery_hash: delivery_hash} = issued_ticket_fixture()
      session = TicketSession.new_browser_session_id()
      stale_fp = TicketSession.generation_fingerprint(delivery_hash)

      assert {:ok, :bound} =
               TicketSession.bind(
                 session,
                 ticket_issue_id,
                 0,
                 stale_fp,
                 TicketSession.session_idle_ttl_seconds()
               )

      assert {:error, :not_found} =
               TicketSessionReader.resolve(session, ticket_issue_id,
                 after_artifact: fn ->
                   rotate_issue!(ticket_issue_id)
                 end
               )

      assert {:error, :not_found} = TicketSession.fetch_binding(session, ticket_issue_id)
    end

    test "registry disappears before TTL refresh still returns artifact for current request" do
      %{ticket_issue_id: ticket_issue_id, delivery_hash: delivery_hash} = issued_ticket_fixture()
      session = TicketSession.new_browser_session_id()
      fp = TicketSession.generation_fingerprint(delivery_hash)

      assert {:ok, :bound} =
               TicketSession.bind(
                 session,
                 ticket_issue_id,
                 0,
                 fp,
                 TicketSession.session_idle_ttl_seconds()
               )

      assert {:ok, %Artifact{}} =
               TicketSessionReader.resolve(session, ticket_issue_id,
                 after_artifact: fn ->
                   Redix.command!(FastCheck.Redix, ["DEL", TicketSession.registry_key(session)])
                 end
               )

      refute redis_key_exists?(session)

      assert {:error, :not_found} = TicketSessionReader.resolve(session, ticket_issue_id)
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
        [event_id, "Reader Offer #{System.unique_integer([:positive])}"]
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
        ["FC-RD-#{System.unique_integer([:positive])}", event_id]
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

  defp system_actor, do: %{actor_type: :system, actor_id: "ticket_session_reader_test"}
end
