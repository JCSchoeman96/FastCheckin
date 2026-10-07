defmodule FastCheckWeb.SecureTicketSessionControllerTest do
  use FastCheckWeb.ConnCase, async: false

  import Ecto.Query

  alias Ash.Changeset
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Fixtures
  alias FastCheck.Redis.Namespace
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Tickets.DeliveryToken
  alias FastCheck.Tickets.TicketSession
  alias FastCheck.Tickets.TokenHash
  alias FastCheckWeb.SecureTicketSessionCookie
  alias Plug.CSRFProtection

  setup do
    cleanup_exchange_rate_keys()
    on_exit(fn -> cleanup_exchange_rate_keys() end)
    :ok
  end

  describe "POST /t/session" do
    test "requires CSRF protection", %{conn: _conn} do
      conn =
        build_conn()
        |> enable_csrf_protection()
        |> Plug.Test.init_test_session(%{})
        |> get("/t")
        |> recycle()
        |> enable_csrf_protection()
        |> post("/t/session", %{
          "_csrf_token" => "invalid",
          "delivery_token" => "bearer"
        })

      assert conn.status == 403
    end

    test "valid delivery_token in body exchanges and sets session cookie", %{conn: conn} do
      %{token: token, ticket_issue_id: ticket_issue_id} = issued_ticket_fixture()

      conn = post_session(conn, %{"delivery_token" => token})

      assert conn.status == 200

      assert %{"redirect_to" => redirect} = json_response(conn, 200)
      assert redirect == "/t/view/#{ticket_issue_id}"

      cookie = session_cookie(conn)
      assert cookie != nil
      assert {:ok, browser_session_id} = SecureTicketSessionCookie.verify(cookie)
      assert byte_size(browser_session_id) > 0

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      refute response_includes_secrets(conn, token, browser_session_id, cookie)
    end

    test "rejects delivery_token in query even when body is valid", %{conn: conn} do
      %{token: token} = issued_ticket_fixture()

      conn =
        post_session_with_path(
          conn,
          "/t/session?delivery_token=#{URI.encode_www_form(token)}",
          %{"delivery_token" => token}
        )

      assert conn.status == 422
      assert json_response(conn, 422) == %{"error" => "ticket_unavailable"}
      refute session_cookie(conn)
    end

    test "rejects query-only delivery_token", %{conn: conn} do
      %{token: token} = issued_ticket_fixture()

      conn =
        post_session_with_path(
          conn,
          "/t/session?delivery_token=#{URI.encode_www_form(token)}",
          %{}
        )

      assert conn.status == 422
      refute session_cookie(conn)
    end

    test "denies missing body token", %{conn: conn} do
      conn = post_session(conn, %{})
      assert conn.status == 422
      refute session_cookie(conn)
    end

    test "reuses browser session when cookie is valid", %{conn: conn} do
      %{token: token} = issued_ticket_fixture()
      existing = TicketSession.new_browser_session_id()

      conn =
        post_session(conn, %{"delivery_token" => token},
          req_cookie: SecureTicketSessionCookie.sign(existing)
        )

      assert conn.status == 200
      cookie = session_cookie(conn)
      assert {:ok, returned} = SecureTicketSessionCookie.verify(cookie)
      assert returned == existing
    end

    test "ignores tampered cookie and may create fresh session", %{conn: conn} do
      %{token: token} = issued_ticket_fixture()

      conn =
        post_session(conn, %{"delivery_token" => token}, req_cookie: "tampered-value")

      assert conn.status == 200
      cookie = session_cookie(conn)
      assert {:ok, _} = SecureTicketSessionCookie.verify(cookie)
      refute cookie == "tampered-value"
    end

    test "two valid bearers share one browser session cookie and independent redis bindings", %{
      conn: conn
    } do
      %{token: token_a, ticket_issue_id: id_a} = issued_ticket_fixture()
      %{token: token_b, ticket_issue_id: id_b} = issued_ticket_fixture()

      conn_a = post_session(conn, %{"delivery_token" => token_a})
      cookie_a = session_cookie(conn_a)
      {:ok, session_a} = SecureTicketSessionCookie.verify(cookie_a)

      conn_b =
        build_conn()
        |> post_session(%{"delivery_token" => token_b}, req_cookie: cookie_a)

      assert conn_b.status == 200
      cookie_b = session_cookie(conn_b)
      {:ok, session_b} = SecureTicketSessionCookie.verify(cookie_b)
      assert session_a == session_b

      assert redis_hget(session_a, id_a) != nil
      assert redis_hget(session_a, id_b) != nil
    end

    test "invalid bearer returns generic failure without Set-Cookie", %{conn: conn} do
      conn = post_session(conn, %{"delivery_token" => "not-valid-bearer"})
      assert conn.status == 422
      assert json_response(conn, 422) == %{"error" => "ticket_unavailable"}
      refute session_cookie(conn)
    end

    test "rate limit exceeded returns 429 without cookie", %{conn: conn} do
      %{token: token} = issued_ticket_fixture()

      for _ <- 1..5 do
        conn = post_session(build_conn(), %{"delivery_token" => token})
        assert conn.status == 200
      end

      conn = post_session(build_conn(), %{"delivery_token" => token})
      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") != []
      refute session_cookie(conn)
    end

    test "session cookie attributes", %{conn: conn} do
      %{token: token} = issued_ticket_fixture()
      conn = post_session(conn, %{"delivery_token" => token})

      [set_cookie] = get_resp_header(conn, "set-cookie")
      assert set_cookie =~ "_fastcheck_ticket_session="
      assert String.downcase(set_cookie) =~ "path=/t"
      assert set_cookie =~ "HttpOnly"
      assert set_cookie =~ "SameSite=Lax"
      refute set_cookie =~ "Max-Age"
    end
  end

  defp enable_csrf_protection(conn) do
    conn
    |> Map.update!(:private, &Map.delete(&1, :plug_skip_csrf_protection))
    |> Plug.Conn.put_private(:phoenix_recycled, true)
  end

  defp post_session(conn, params, opts \\ []) do
    post_session_with_path(conn, "/t/session", params, opts)
  end

  defp post_session_with_path(conn, path, params, opts \\ []) do
    req_cookie = Keyword.get(opts, :req_cookie)

    conn =
      conn
      |> enable_csrf_protection()
      |> then(fn c ->
        if req_cookie do
          put_req_cookie(c, SecureTicketSessionCookie.cookie_name(), req_cookie)
        else
          c
        end
      end)

    _conn = get(conn, "/t")
    csrf = CSRFProtection.get_csrf_token()

    conn
    |> recycle()
    |> enable_csrf_protection()
    |> then(fn recycled ->
      if req_cookie do
        put_req_cookie(recycled, SecureTicketSessionCookie.cookie_name(), req_cookie)
      else
        recycled
      end
    end)
    |> put_req_header("x-csrf-token", csrf)
    |> put_req_header("accept", "application/json")
    |> post(path, params)
  end

  defp session_cookie(conn) do
    conn.resp_cookies
    |> Map.get(SecureTicketSessionCookie.cookie_name())
    |> case do
      %{value: value} -> value
      _ -> nil
    end
  end

  defp response_includes_secrets(conn, token, browser_session_id, cookie) do
    body = conn.resp_body
    body =~ token or body =~ browser_session_id or body =~ cookie
  end

  defp cleanup_exchange_rate_keys do
    pattern = Namespace.pattern("rate-limit:secure-ticket:*")

    case Redix.command(FastCheck.Redix, ["KEYS", pattern]) do
      {:ok, keys} when keys != [] ->
        _ = Redix.command(FastCheck.Redix, ["DEL" | Namespace.ensure_scoped_keys!(keys)])

      _ ->
        :ok
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

    attendee
    |> Attendee.changeset(%{sales_ticket_issue_id: ticket_issue.id})
    |> Repo.update!()

    %{token: token, ticket_issue_id: ticket_issue.id}
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
        [event_id, "Session Exchange Offer #{System.unique_integer([:positive])}"]
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
        ["FC-SE-#{System.unique_integer([:positive])}", event_id]
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

  defp system_actor, do: %{actor_type: :system, actor_id: "secure_ticket_session_controller_test"}
end
