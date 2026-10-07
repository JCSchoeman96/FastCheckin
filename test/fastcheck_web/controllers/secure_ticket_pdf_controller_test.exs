defmodule FastCheckWeb.SecureTicketPdfControllerTest do
  use FastCheckWeb.ConnCase, async: false

  alias Ash.Changeset
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Fixtures
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Tickets.{DeliveryToken, TicketSession, TokenHash}
  alias FastCheckWeb.SecureTicketSessionCookie

  @failure "Ticket PDF is not available for download."

  setup do
    previous_limit =
      Application.get_env(:fastcheck, FastCheck.RateLimiter, [])
      |> Keyword.get(:secure_ticket_limit)

    rate_config = Application.get_env(:fastcheck, FastCheck.RateLimiter, [])

    Application.put_env(
      :fastcheck,
      FastCheck.RateLimiter,
      Keyword.put(rate_config, :secure_ticket_limit, 100)
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

  describe "GET /t/:token/pdf legacy bearer rejection (P1E-F)" do
    test "route metadata disables router dispatch logging and targets reject_legacy" do
      route =
        Enum.find(FastCheckWeb.Router.__routes__(), fn route ->
          route.path == "/t/:token/pdf" and route.verb == :get
        end)

      assert %{
               metadata: %{log: false},
               plug: FastCheckWeb.SecureTicketPdfController,
               plug_opts: :reject_legacy
             } = route
    end

    test "random bearer returns constant 404 without PDF body" do
      unknown_token = DeliveryToken.generate().token
      assert_legacy_pdf_rejected(unknown_token)
    end

    test "valid bearer returns same 404 without PDF body" do
      %{token: token, delivery_hash: delivery_hash, qr_hash: qr_hash, ticket_code: ticket_code} =
        issued_ticket_fixture()

      assert_legacy_pdf_rejected(token, sensitive: [token, delivery_hash, qr_hash, ticket_code])
    end

    test "expired bearer returns same 404 as valid bearer" do
      %{token: token, delivery_hash: delivery_hash} =
        issued_ticket_fixture(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))

      assert_legacy_pdf_rejected(token, sensitive: [token, delivery_hash])
    end

    test "valid legacy bearer performs zero Repo queries during request" do
      %{token: token} = issued_ticket_fixture()

      {_conn, query_count} =
        capture_repo_queries(fn ->
          get_pdf(token)
        end)

      assert query_count == 0
    end

    test "pre-limit rejection is 404 regardless of token validity" do
      valid = issued_ticket_fixture().token
      random = DeliveryToken.generate().token

      assert get_pdf(valid).status == 404
      assert get_pdf(random).status == 404
    end
  end

  describe "GET /t/view/:ticket_issue_id/pdf" do
    test "downloads PDF for bound browser session without delivery bearer" do
      %{
        token: token,
        ticket_issue_id: ticket_issue_id,
        delivery_hash: delivery_hash
      } = issued_ticket_fixture()

      session = TicketSession.new_browser_session_id()
      bind_session!(session, ticket_issue_id, delivery_hash)

      conn =
        build_conn()
        |> put_req_cookie(
          SecureTicketSessionCookie.cookie_name(),
          SecureTicketSessionCookie.sign(session)
        )
        |> get(~p"/t/view/#{ticket_issue_id}/pdf")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/pdf"
      refute conn.resp_body =~ token
    end

    test "missing cookie returns 404 without PDF body" do
      %{ticket_issue_id: ticket_issue_id, token: token} = issued_ticket_fixture()

      conn = get(build_conn(), ~p"/t/view/#{ticket_issue_id}/pdf")

      assert conn.status == 404
      assert response(conn, 404) == @failure
      refute conn.resp_body =~ token
    end

    test "redis unavailable returns 503" do
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
        build_conn()
        |> put_req_cookie(
          SecureTicketSessionCookie.cookie_name(),
          SecureTicketSessionCookie.sign(session)
        )
        |> get(~p"/t/view/#{ticket_issue_id}/pdf")

      assert conn.status == 503
    end
  end

  defp assert_legacy_pdf_rejected(token, opts \\ []) do
    sensitive = Keyword.get(opts, :sensitive, [token])
    conn = get_pdf(token)

    assert conn.status == 404
    assert get_resp_header(conn, "location") == []
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/plain"
    assert conn.resp_body == @failure
    refute String.starts_with?(conn.resp_body, "%PDF-")

    assert {"cache-control", "no-store, private"} in conn.resp_headers
    assert {"pragma", "no-cache"} in conn.resp_headers
    assert {"x-robots-tag", "noindex, nofollow"} in conn.resp_headers
    assert {"referrer-policy", "no-referrer"} in conn.resp_headers

    response_text = response_text(conn)

    Enum.each(sensitive, fn value ->
      refute response_text =~ value
    end)
  end

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    ref = make_ref()
    handler_id = "secure-ticket-legacy-pdf-#{System.unique_integer([:positive])}"
    parent = self()
    event_name = (Repo.config()[:telemetry_prefix] || [:fastcheck, :repo]) ++ [:query]

    :telemetry.attach(
      handler_id,
      event_name,
      fn _event, _measurements, _metadata, _config ->
        send(parent, {:repo_query, ref})
      end,
      nil
    )

    try do
      result = fun.()
      query_count = drain_repo_query_messages(ref, 0)
      {result, query_count}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_query_messages(ref, count) do
    receive do
      {:repo_query, ^ref} -> drain_repo_query_messages(ref, count + 1)
    after
      0 -> count
    end
  end

  defp get_pdf(token), do: get(build_conn(), "/t/#{token}/pdf")

  defp response_text(conn) do
    headers = Enum.map_join(conn.resp_headers, "\n", fn {name, value} -> "#{name}: #{value}" end)
    "#{conn.resp_body}\n#{headers}"
  end

  defp issued_ticket_fixture(opts \\ []) do
    event = Fixtures.create_event()
    attendee = Fixtures.create_attendee(event, %{payment_status: "completed"})
    ticket_code = attendee.ticket_code

    %{token: token, hash: delivery_hash, expires_at: expires_at} =
      DeliveryToken.generate(
        now: DateTime.utc_now() |> DateTime.truncate(:second),
        ttl_seconds: 3600
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
             |> Changeset.for_create(:create_issued_link, attrs,
               actor: %{actor_type: :system, actor_id: "secure_ticket_pdf_controller_test"}
             )
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
      qr_hash: qr_hash,
      ticket_code: ticket_code,
      ticket_issue_id: ticket_issue.id,
      order_id: order_id,
      event: event,
      attendee: attendee
    }
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
        [event_id, "Secure PDF Offer #{System.unique_integer([:positive])}"]
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
end
