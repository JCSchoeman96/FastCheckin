defmodule FastCheckWeb.Sales.TicketPdfControllerTest do
  use FastCheckWeb.ConnCase, async: false

  import Ecto.Query

  alias Ash.Changeset
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event
  alias FastCheck.Fixtures
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Tickets.{DeliveryToken, TokenHash}
  alias FastCheckWeb.SalesWebFixtures, as: WebFixtures

  @failure "Ticket PDF is not available for download."
  @forbidden_header_values [
    "ORDER_SHOW_ACCESS",
    "https://checkout.paystack.test/pay/order-show-secret",
    "provider_payload_secret",
    "buyer@example.test",
    "+27821234567"
  ]

  setup do
    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: WebFixtures.dashboard_username(),
      password: "fastcheck"
    })

    :ok
  end

  test "unauthenticated request redirects to login", %{conn: conn} do
    conn = get(conn, ~p"/dashboard/sales/tickets/1/pdf")

    assert redirected_to(conn) =~ "/login"
  end

  test "authenticated admin downloads a valid issued ticket PDF", %{conn: conn} do
    %{
      ticket_issue_id: ticket_issue_id,
      ticket_code: ticket_code,
      token: token,
      delivery_hash: delivery_hash,
      qr_hash: qr_hash
    } = issued_ticket_fixture()

    conn =
      conn
      |> WebFixtures.authenticated_conn()
      |> get(~p"/dashboard/sales/tickets/#{ticket_issue_id}/pdf")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/pdf"

    assert get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"fastcheck-ticket.pdf\""
           ]

    assert get_resp_header(conn, "cache-control") == ["no-store, private"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    assert String.starts_with?(conn.resp_body, "%PDF-")
    assert conn.resp_body =~ "% FastCheck QR matrix modules="
    assert conn.resp_body =~ "Ticket code: #{ticket_code}"

    header_text =
      Enum.map_join(conn.resp_headers, "\n", fn {name, value} -> "#{name}: #{value}" end)

    refute header_text =~ ticket_code
    refute header_text =~ token
    refute header_text =~ delivery_hash
    refute header_text =~ qr_hash

    Enum.each(@forbidden_header_values, fn value ->
      refute header_text =~ value
    end)
  end

  test "expired delivery link does not block admin PDF download", %{conn: conn} do
    %{ticket_issue_id: ticket_issue_id, ticket_code: ticket_code} =
      issued_ticket_fixture(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))

    conn =
      conn
      |> WebFixtures.authenticated_conn()
      |> get(~p"/dashboard/sales/tickets/#{ticket_issue_id}/pdf")

    assert conn.status == 200
    assert conn.resp_body =~ "Ticket code: #{ticket_code}"
  end

  test "invalid id and missing ticket issue return generic safe failure" do
    for ticket_issue_id <- ["not-an-id", "999999999"] do
      conn =
        build_conn()
        |> WebFixtures.authenticated_conn()
        |> get(~p"/dashboard/sales/tickets/#{ticket_issue_id}/pdf")

      assert conn.status == 404
      assert conn.resp_body == @failure
    end
  end

  test "revoked not scannable archived and not issued tickets do not download PDFs", %{conn: conn} do
    %{ticket_issue_id: revoked_id} =
      issued_ticket_fixture(status: "revoked", revoked_at: DateTime.utc_now())

    assert_failure(conn, revoked_id, 410)

    %{ticket_issue_id: pending_id} = issued_ticket_fixture(status: "pending")
    assert_failure(conn, pending_id, 409)

    %{ticket_issue_id: archived_id, event: event} = issued_ticket_fixture()

    event
    |> Event.changeset(%{status: "archived"})
    |> Repo.update!()

    assert_failure(conn, archived_id, 409)

    %{ticket_issue_id: not_scannable_id, attendee: attendee} = issued_ticket_fixture()

    attendee
    |> Attendee.changeset(%{scan_eligibility: "not_scannable"})
    |> Repo.update!()

    assert_failure(conn, not_scannable_id, 409)
  end

  test "missing attendee missing event and malformed payload return generic safe failures", %{
    conn: conn
  } do
    %{ticket_issue_id: missing_attendee_id} = issued_ticket_fixture()

    Repo.query!("UPDATE sales_ticket_issues SET attendee_id = $1 WHERE id = $2", [
      999_999_999,
      missing_attendee_id
    ])

    assert_failure(conn, missing_attendee_id, 409)

    %{ticket_issue_id: missing_event_id, order_id: order_id} = issued_ticket_fixture()

    Repo.query!("UPDATE sales_orders SET event_id = $1 WHERE id = $2", [999_999_999, order_id])

    assert_failure(conn, missing_event_id, 409)

    %{ticket_issue_id: malformed_id, ticket_code: ticket_code} = issued_ticket_fixture()

    Repo.query!("UPDATE sales_ticket_issues SET ticket_code = $1 WHERE id = $2", [
      ticket_code <> "\nBAD",
      malformed_id
    ])

    conn =
      conn
      |> recycle()
      |> WebFixtures.authenticated_conn()
      |> get(~p"/dashboard/sales/tickets/#{malformed_id}/pdf")

    assert conn.status == 500
    assert conn.resp_body == @failure
    refute conn.resp_body =~ ticket_code
  end

  test "PDF download does not mutate ticket attendee order payment or delivery rows", %{
    conn: conn
  } do
    %{ticket_issue_id: ticket_issue_id, attendee: attendee, order_id: order_id} =
      issued_ticket_fixture()

    counts_before = row_counts(ticket_issue_id, attendee.id, order_id)

    conn
    |> WebFixtures.authenticated_conn()
    |> get(~p"/dashboard/sales/tickets/#{ticket_issue_id}/pdf")

    assert row_counts(ticket_issue_id, attendee.id, order_id) == counts_before
  end

  defp assert_failure(conn, ticket_issue_id, status) do
    conn =
      conn
      |> recycle()
      |> WebFixtures.authenticated_conn()
      |> get(~p"/dashboard/sales/tickets/#{ticket_issue_id}/pdf")

    assert conn.status == status
    assert conn.resp_body == @failure
    refute String.starts_with?(conn.resp_body, "%PDF-")
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
      qr_hash: qr_hash,
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
        [event_id, "Admin Ticket PDF Offer #{System.unique_integer([:positive])}"]
      )
      |> Map.fetch!(:rows)
      |> List.first()
      |> List.first()

    order_id =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_email, buyer_phone, source_channel,
           status, total_amount_cents, currency, inserted_at, updated_at)
        VALUES
          ($1, $2, 'Buyer', 'buyer@example.test', '+27821234567', 'whatsapp',
           'ticket_issued', 100, 'ZAR', now(), now())
        RETURNING id
        """,
        ["FC-TPDF-#{System.unique_integer([:positive])}", event_id]
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

  defp system_actor, do: %{actor_type: :system, actor_id: "ticket_pdf_controller_test"}
end
