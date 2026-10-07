defmodule FastCheckWeb.SecureTicketControllerTest do
  use FastCheckWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ash.Changeset
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Fixtures
  alias FastCheck.Redis.Namespace
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Tickets.{DeliveryToken, TicketRateLimiter, TicketSession, TokenHash}
  alias FastCheckWeb.SecureTicketSessionCookie

  setup do
    previous_limit =
      Application.get_env(:fastcheck, FastCheck.RateLimiter, [])
      |> Keyword.get(:secure_ticket_limit)

    rate_config = Application.get_env(:fastcheck, FastCheck.RateLimiter, [])

    Application.put_env(
      :fastcheck,
      FastCheck.RateLimiter,
      Keyword.put(rate_config, :secure_ticket_limit, 5)
    )

    on_exit(fn ->
      rate_config = Application.get_env(:fastcheck, FastCheck.RateLimiter, [])

      rate_config =
        if previous_limit do
          Keyword.put(rate_config, :secure_ticket_limit, previous_limit)
        else
          Keyword.delete(rate_config, :secure_ticket_limit)
        end

      Application.put_env(:fastcheck, FastCheck.RateLimiter, rate_config)
    end)

    :ok
  end

  describe "GET /t bootstrap" do
    test "returns bootstrap page without embedding a bearer", %{conn: conn} do
      conn = get(conn, "/t")
      html = html_response(conn, 200)

      assert html =~ "Opening your ticket"
      refute html =~ "delivery_token"
      assert get_resp_header(conn, "cache-control") == ["no-store, private"]
    end

    test "route metadata disables router dispatch logging for bootstrap" do
      route =
        Enum.find(FastCheckWeb.Router.__routes__(), fn route ->
          route.path == "/t" and route.verb == :get
        end)

      assert %{metadata: %{log: false}, plug: FastCheckWeb.SecureTicketController} = route
    end
  end

  describe "GET /t/:token" do
    test "route metadata disables router dispatch logging" do
      route =
        Enum.find(FastCheckWeb.Router.__routes__(), fn route ->
          route.path == "/t/:token" and route.verb == :get
        end)

      assert %{
               metadata: %{log: false},
               plug: FastCheckWeb.SecureTicketController
             } = route
    end

    test "is public and does not redirect to login", %{conn: conn} do
      %{token: token, event: event} = issued_ticket_fixture()

      conn = get(conn, ~p"/t/#{token}")

      assert conn.status == 200
      assert get_resp_header(conn, "location") == []
      assert html_response(conn, 200) =~ event.name
    end

    test "valid response shows safe ticket fields and ticket code", %{conn: conn} do
      %{token: token, ticket_code: ticket_code, event: event, attendee: attendee} =
        issued_ticket_fixture()

      html = conn |> get(~p"/t/#{token}") |> html_response(200)

      assert html =~ event.name
      assert html =~ attendee.first_name
      assert html =~ ticket_code
      assert html =~ "Download PDF"
      assert html =~ ~s(href="/t/#{token}/pdf")
    end

    test "invalid token omits ticket code from HTML", %{conn: conn} do
      %{ticket_code: ticket_code} = issued_ticket_fixture()
      unknown = DeliveryToken.generate().token

      html = conn |> get(~p"/t/#{unknown}") |> html_response(404)

      refute html =~ ticket_code
      refute html =~ "Download PDF"
    end

    test "expired token omits ticket code from HTML", %{conn: conn} do
      %{token: token, ticket_code: ticket_code} =
        issued_ticket_fixture(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))

      html = conn |> get(~p"/t/#{token}") |> html_response(410)

      refute html =~ ticket_code
      refute html =~ "Download PDF"
    end

    test "revoked ticket omits ticket code from HTML", %{conn: conn} do
      %{token: token, ticket_code: ticket_code} =
        issued_ticket_fixture(status: "revoked", revoked_at: DateTime.utc_now())

      html = conn |> get(~p"/t/#{token}") |> html_response(200)

      refute html =~ ticket_code
      refute html =~ "Download PDF"
    end

    test "not-ready ticket omits ticket code from HTML", %{conn: conn} do
      %{token: token, ticket_code: ticket_code} = issued_ticket_fixture(status: "pending")

      html = conn |> get(~p"/t/#{token}") |> html_response(200)

      refute html =~ ticket_code
      refute html =~ "Download PDF"
    end

    test "not_scannable attendee omits ticket code from HTML", %{conn: conn} do
      %{token: token, ticket_code: ticket_code, attendee: attendee} = issued_ticket_fixture()

      attendee
      |> Attendee.changeset(%{scan_eligibility: "not_scannable"})
      |> Repo.update!()

      html = conn |> get(~p"/t/#{token}") |> html_response(200)

      refute html =~ ticket_code
      refute html =~ "Download PDF"
    end

    test "sets no-store private and noindex headers", %{conn: conn} do
      %{token: token} = issued_ticket_fixture()

      conn = get(conn, ~p"/t/#{token}")

      assert {"cache-control", "no-store, private"} in conn.resp_headers
      assert {"pragma", "no-cache"} in conn.resp_headers
      assert {"x-robots-tag", "noindex, nofollow"} in conn.resp_headers
      assert {"referrer-policy", "no-referrer"} in conn.resp_headers
    end

    test "burst invalid-token requests from same IP eventually return 429", %{conn: conn} do
      token = DeliveryToken.generate().token

      final_conn =
        Enum.reduce(1..6, conn, fn _n, _acc ->
          conn
          |> non_local_conn()
          |> get(~p"/t/#{token}")
        end)

      assert final_conn.status == 429
    end

    test "captured logs do not include raw route token", %{conn: conn} do
      %{token: token} = issued_ticket_fixture()

      log =
        capture_log(fn ->
          get(conn, ~p"/t/#{token}")
        end)

      refute log =~ token
    end

    test "rate-limit blocked log does not include raw /t/token path", %{conn: conn} do
      token = DeliveryToken.generate().token
      conn = non_local_conn(conn)

      log =
        capture_log([level: :warning], fn ->
          Enum.each(1..6, fn _ -> get(conn, ~p"/t/#{token}") end)
        end)

      refute log =~ "/t/#{token}"
      assert log =~ "/t/[FILTERED]"
    end

    test "does not mutate ticket, attendee, order, payment, or delivery rows", %{conn: conn} do
      %{token: token, ticket_issue_id: ticket_issue_id, attendee: attendee, order_id: order_id} =
        issued_ticket_fixture()

      counts_before = row_counts(ticket_issue_id, attendee.id, order_id)

      get(conn, ~p"/t/#{token}")

      assert row_counts(ticket_issue_id, attendee.id, order_id) == counts_before
    end
  end

  defp row_counts(ticket_issue_id, attendee_id, order_id) do
    %{
      ticket_issues: count_table("sales_ticket_issues", ticket_issue_id),
      attendees: count_table("attendees", attendee_id),
      orders: count_table("sales_orders", order_id),
      payment_attempts: Repo.one!(from p in "sales_payment_attempts", select: count(p.id)),
      delivery_attempts: Repo.one!(from d in "sales_delivery_attempts", select: count(d.id))
    }
  end

  defp count_table(table, id) do
    Repo.one!(from t in table, where: t.id == ^id, select: count(t.id))
  end

  defp issued_ticket_fixture(opts \\ []) do
    event = Fixtures.create_event()
    attendee = Fixtures.create_attendee(event, %{payment_status: "completed"})
    ticket_code = attendee.ticket_code

    %{token: token, hash: delivery_hash, expires_at: expires_at} =
      DeliveryToken.generate(
        now: DateTime.utc_now() |> DateTime.truncate(:second),
        ttl_seconds: Keyword.get(opts, :ttl_seconds, 3600)
      )

    expires_at = Keyword.get(opts, :expires_at, expires_at)
    status = Keyword.get(opts, :status, "issued")
    revoked_at = Keyword.get(opts, :revoked_at)

    {order_id, order_line_id} = insert_order_with_line!(event.id)

    attrs = %{
      sales_order_id: order_id,
      sales_order_line_id: order_line_id,
      line_item_sequence: 1,
      attendee_id: attendee.id,
      ticket_code: ticket_code,
      qr_token_hash: TokenHash.hash("qr-#{System.unique_integer([:positive])}", :qr),
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

    attendee
    |> Attendee.changeset(%{sales_ticket_issue_id: ticket_issue.id})
    |> Repo.update!()

    %{
      token: token,
      ticket_code: ticket_code,
      ticket_issue_id: ticket_issue.id,
      delivery_hash: delivery_hash,
      order_id: order_id,
      event: event,
      attendee: attendee
    }
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
        [event_id, "Secure Ticket Offer #{System.unique_integer([:positive])}"]
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
        ["FC-ST-#{System.unique_integer([:positive])}", event_id]
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

  defp system_actor, do: %{actor_type: :system, actor_id: "secure_ticket_controller_test"}

  defp non_local_conn(conn) do
    Plug.Conn.put_req_header(conn, "x-forwarded-for", "10.0.0.55")
  end

  describe "GET /t/view/:ticket_issue_id" do
    setup do
      cleanup_session_read_rate_keys()
      on_exit(fn -> cleanup_session_read_rate_keys() end)
      :ok
    end

    test "route metadata disables router dispatch logging" do
      html_route =
        Enum.find(FastCheckWeb.Router.__routes__(), fn route ->
          route.path == "/t/view/:ticket_issue_id" and route.verb == :get
        end)

      assert %{
               metadata: %{log: false},
               plug: FastCheckWeb.SecureTicketController,
               plug_opts: :view
             } = html_route

      pdf_route =
        Enum.find(FastCheckWeb.Router.__routes__(), fn route ->
          route.path == "/t/view/:ticket_issue_id/pdf" and route.verb == :get
        end)

      assert %{
               metadata: %{log: false},
               plug: FastCheckWeb.SecureTicketPdfController,
               plug_opts: :view
             } = pdf_route
    end

    test "GET /t/pdf is not a generic ticket route", %{conn: conn} do
      conn = get(conn, "/t/pdf")
      assert conn.status in [404, 302]
      refute conn.status == 200
    end

    test "valid session shows ticket fields and safe PDF link without delivery bearer", %{
      conn: conn
    } do
      %{
        token: token,
        ticket_issue_id: ticket_issue_id,
        ticket_code: ticket_code,
        event: event,
        attendee: attendee,
        delivery_hash: delivery_hash
      } = issued_ticket_fixture()

      session = TicketSession.new_browser_session_id()
      bind_session!(session, ticket_issue_id, delivery_hash)

      conn =
        conn
        |> put_req_cookie(
          SecureTicketSessionCookie.cookie_name(),
          SecureTicketSessionCookie.sign(session)
        )
        |> get(~p"/t/view/#{ticket_issue_id}")

      html = html_response(conn, 200)

      assert html =~ event.name
      assert html =~ attendee.first_name
      assert html =~ ticket_code
      assert html =~ "Download PDF"
      assert html =~ ~s(href="/t/view/#{ticket_issue_id}/pdf")
      refute html =~ token
      refute response_includes_delivery_bearer(conn, token)
    end

    test "missing cookie fails closed without ticket data or session side effects", %{conn: conn} do
      %{ticket_issue_id: ticket_issue_id, ticket_code: ticket_code, token: token} =
        issued_ticket_fixture()

      conn = get(conn, ~p"/t/view/#{ticket_issue_id}")
      html = html_response(conn, 404)

      refute html =~ ticket_code
      refute html =~ "Download PDF"
      refute session_cookie(conn)
      refute redis_registry_exists?(TicketSession.new_browser_session_id())
      refute response_includes_delivery_bearer(conn, token)
    end

    test "invalid cookie fails closed without TTL refresh", %{conn: conn} do
      %{
        ticket_issue_id: ticket_issue_id,
        ticket_code: ticket_code,
        delivery_hash: delivery_hash
      } = issued_ticket_fixture()

      session = TicketSession.new_browser_session_id()
      bind_session!(session, ticket_issue_id, delivery_hash)

      Redix.command!(FastCheck.Redix, [
        "EXPIRE",
        TicketSession.registry_key(session),
        45
      ])

      conn =
        conn
        |> put_req_cookie(SecureTicketSessionCookie.cookie_name(), "not-a-valid-cookie")
        |> get(~p"/t/view/#{ticket_issue_id}")

      html = html_response(conn, 404)
      assert html =~ "not available"
      refute html =~ ticket_code

      ttl = redis_ttl!(session)
      assert ttl in 40..50
    end

    test "route id alone does not authorize another ticket", %{conn: conn} do
      fixture_a = issued_ticket_fixture()
      fixture_b = issued_ticket_fixture()

      session = TicketSession.new_browser_session_id()
      bind_session!(session, fixture_a.ticket_issue_id, fixture_a.delivery_hash)

      conn =
        conn
        |> put_req_cookie(
          SecureTicketSessionCookie.cookie_name(),
          SecureTicketSessionCookie.sign(session)
        )
        |> get(~p"/t/view/#{fixture_b.ticket_issue_id}")

      html = html_response(conn, 404)
      refute html =~ fixture_b.ticket_code
      refute html =~ fixture_b.event.name
    end

    test "multi-ticket isolation within one browser session", %{conn: conn} do
      fixture_a = issued_ticket_fixture()
      fixture_b = issued_ticket_fixture()
      session = TicketSession.new_browser_session_id()

      bind_session!(session, fixture_a.ticket_issue_id, fixture_a.delivery_hash)
      bind_session!(session, fixture_b.ticket_issue_id, fixture_b.delivery_hash)

      cookie = SecureTicketSessionCookie.sign(session)

      html_a =
        conn
        |> put_req_cookie(SecureTicketSessionCookie.cookie_name(), cookie)
        |> get(~p"/t/view/#{fixture_a.ticket_issue_id}")
        |> html_response(200)

      assert html_a =~ fixture_a.ticket_code
      refute html_a =~ fixture_b.ticket_code

      html_b =
        conn
        |> put_req_cookie(SecureTicketSessionCookie.cookie_name(), cookie)
        |> get(~p"/t/view/#{fixture_b.ticket_issue_id}")
        |> html_response(200)

      assert html_b =~ fixture_b.ticket_code
      refute html_b =~ fixture_a.ticket_code
    end

    test "stale generation after rotation does not return artifact", %{conn: conn} do
      %{
        ticket_issue_id: ticket_issue_id,
        delivery_hash: delivery_hash,
        ticket_code: ticket_code
      } = issued_ticket_fixture()

      session = TicketSession.new_browser_session_id()
      bind_session!(session, ticket_issue_id, delivery_hash, 0)

      rotate_delivery_token!(ticket_issue_id)

      conn =
        conn
        |> put_req_cookie(
          SecureTicketSessionCookie.cookie_name(),
          SecureTicketSessionCookie.sign(session)
        )
        |> get(~p"/t/view/#{ticket_issue_id}")

      html = html_response(conn, 404)
      refute html =~ ticket_code
      assert redis_hget(session, ticket_issue_id) == nil
    end

    test "expired delivery token omits ticket fields", %{conn: conn} do
      %{
        ticket_issue_id: ticket_issue_id,
        delivery_hash: delivery_hash,
        ticket_code: ticket_code
      } =
        issued_ticket_fixture(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))

      session = TicketSession.new_browser_session_id()
      bind_session!(session, ticket_issue_id, delivery_hash)

      conn =
        conn
        |> put_req_cookie(
          SecureTicketSessionCookie.cookie_name(),
          SecureTicketSessionCookie.sign(session)
        )
        |> get(~p"/t/view/#{ticket_issue_id}")

      assert conn.status == 410
      refute html_response(conn, 410) =~ ticket_code
    end

    test "redis unavailable returns 503 without ticket data", %{conn: conn} do
      %{
        ticket_issue_id: ticket_issue_id,
        delivery_hash: delivery_hash
      } = issued_ticket_fixture()

      session = TicketSession.new_browser_session_id()
      bind_session!(session, ticket_issue_id, delivery_hash)

      assert :ok = Supervisor.terminate_child(FastCheck.Redis.Connection, FastCheck.Redix)

      on_exit(fn ->
        {:ok, _} = Supervisor.restart_child(FastCheck.Redis.Connection, FastCheck.Redix)
      end)

      conn =
        conn
        |> put_req_cookie(
          SecureTicketSessionCookie.cookie_name(),
          SecureTicketSessionCookie.sign(session)
        )
        |> get(~p"/t/view/#{ticket_issue_id}")

      assert conn.status == 503
      refute conn.resp_body =~ "ticket code"
    end

    test "session read rate limit returns 429 with Retry-After", %{conn: conn} do
      %{
        ticket_issue_id: ticket_issue_id,
        delivery_hash: delivery_hash
      } = issued_ticket_fixture()

      session = TicketSession.new_browser_session_id()
      bind_session!(session, ticket_issue_id, delivery_hash)

      key = TicketRateLimiter.session_read_redis_key(session)
      now_usec = redis_now_usec()

      for i <- 1..120 do
        member = "#{now_usec + i}:#{i}"
        Redix.command!(FastCheck.Redix, ["ZADD", key, Integer.to_string(now_usec + i), member])
      end

      Redix.command!(FastCheck.Redix, ["EXPIRE", key, 120])

      conn =
        conn
        |> put_req_cookie(
          SecureTicketSessionCookie.cookie_name(),
          SecureTicketSessionCookie.sign(session)
        )
        |> get(~p"/t/view/#{ticket_issue_id}")

      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") != []
    end

    test "does not mutate ticket, attendee, order, payment, or delivery rows", %{conn: conn} do
      %{
        ticket_issue_id: ticket_issue_id,
        delivery_hash: delivery_hash,
        attendee: attendee,
        order_id: order_id
      } = issued_ticket_fixture()

      session = TicketSession.new_browser_session_id()
      bind_session!(session, ticket_issue_id, delivery_hash)

      counts_before = row_counts(ticket_issue_id, attendee.id, order_id)

      conn
      |> put_req_cookie(
        SecureTicketSessionCookie.cookie_name(),
        SecureTicketSessionCookie.sign(session)
      )
      |> get(~p"/t/view/#{ticket_issue_id}")

      assert row_counts(ticket_issue_id, attendee.id, order_id) == counts_before
    end
  end

  defp bind_session!(session, ticket_issue_id, delivery_hash, generation \\ 0) do
    fp = TicketSession.generation_fingerprint(delivery_hash)

    assert {:ok, :bound} =
             TicketSession.bind(
               session,
               ticket_issue_id,
               generation,
               fp,
               TicketSession.session_idle_ttl_seconds()
             )
  end

  defp rotate_delivery_token!(ticket_issue_id) do
    %{hash: hash, expires_at: expires_at} = DeliveryToken.generate()

    Repo.query!(
      """
      UPDATE sales_ticket_issues
      SET delivery_token_hash = $1,
          delivery_token_expires_at = $2,
          delivery_token_generation = delivery_token_generation + 1
      WHERE id = $3
      """,
      [hash, expires_at, ticket_issue_id]
    )
  end

  defp redis_hget(session, ticket_issue_id) do
    Redix.command!(FastCheck.Redix, [
      "HGET",
      TicketSession.registry_key(session),
      "ticket:#{ticket_issue_id}"
    ])
  end

  defp redis_ttl!(session) do
    {:ok, ttl} =
      Redix.command(FastCheck.Redix, ["TTL", TicketSession.registry_key(session)])

    ttl
  end

  defp redis_registry_exists?(session) do
    case Redix.command(FastCheck.Redix, ["EXISTS", TicketSession.registry_key(session)]) do
      {:ok, 1} -> true
      _ -> false
    end
  end

  defp redis_now_usec do
    {:ok, [sec, usec]} = Redix.command(FastCheck.Redix, ["TIME"])
    String.to_integer(sec) * 1_000_000 + String.to_integer(usec)
  end

  defp session_cookie(conn) do
    conn.resp_cookies
    |> Map.get(SecureTicketSessionCookie.cookie_name())
    |> case do
      %{value: value} -> value
      _ -> nil
    end
  end

  defp response_includes_delivery_bearer(conn, token) do
    body = conn.resp_body || ""
    headers = Enum.map_join(conn.resp_headers, " ", fn {_, v} -> v end)

    body =~ token or headers =~ token or
      Enum.any?(get_resp_header(conn, "location"), &String.contains?(&1, token))
  end

  defp cleanup_session_read_rate_keys do
    pattern = Namespace.pattern("rate-limit:secure-ticket:*")

    case Redix.command(FastCheck.Redix, ["KEYS", pattern]) do
      {:ok, keys} when keys != [] ->
        _ = Redix.command(FastCheck.Redix, ["DEL" | Namespace.ensure_scoped_keys!(keys)])

      _ ->
        :ok
    end
  end
end
