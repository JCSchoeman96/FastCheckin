defmodule FastCheckWeb.SecureTicketControllerTest do
  use FastCheckWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ash.Changeset
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Fixtures
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Tickets.{DeliveryToken, TokenHash}

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

  describe "GET /t/:token" do
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
    end

    test "invalid token omits ticket code from HTML", %{conn: conn} do
      %{ticket_code: ticket_code} = issued_ticket_fixture()
      unknown = DeliveryToken.generate().token

      html = conn |> get(~p"/t/#{unknown}") |> html_response(404)

      refute html =~ ticket_code
    end

    test "expired token omits ticket code from HTML", %{conn: conn} do
      %{token: token, ticket_code: ticket_code} =
        issued_ticket_fixture(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))

      html = conn |> get(~p"/t/#{token}") |> html_response(410)

      refute html =~ ticket_code
    end

    test "revoked ticket omits ticket code from HTML", %{conn: conn} do
      %{token: token, ticket_code: ticket_code} =
        issued_ticket_fixture(status: "revoked", revoked_at: DateTime.utc_now())

      html = conn |> get(~p"/t/#{token}") |> html_response(200)

      refute html =~ ticket_code
    end

    test "not-ready ticket omits ticket code from HTML", %{conn: conn} do
      %{token: token, ticket_code: ticket_code} = issued_ticket_fixture(status: "pending")

      html = conn |> get(~p"/t/#{token}") |> html_response(200)

      refute html =~ ticket_code
    end

    test "not_scannable attendee omits ticket code from HTML", %{conn: conn} do
      %{token: token, ticket_code: ticket_code, attendee: attendee} = issued_ticket_fixture()

      attendee
      |> Attendee.changeset(%{scan_eligibility: "not_scannable"})
      |> Repo.update!()

      html = conn |> get(~p"/t/#{token}") |> html_response(200)

      refute html =~ ticket_code
    end

    test "sets no-store private and noindex headers", %{conn: conn} do
      %{token: token} = issued_ticket_fixture()

      conn = get(conn, ~p"/t/#{token}")

      assert {"cache-control", "no-store, private"} in conn.resp_headers
      assert {"pragma", "no-cache"} in conn.resp_headers
      assert {"x-robots-tag", "noindex, nofollow"} in conn.resp_headers
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
end
