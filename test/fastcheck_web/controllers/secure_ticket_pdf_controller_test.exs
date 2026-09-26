defmodule FastCheckWeb.SecureTicketPdfControllerTest do
  use FastCheckWeb.ConnCase, async: false

  import Ecto.Query

  alias Ash.Changeset
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event
  alias FastCheck.Fixtures
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Tickets.{DeliveryToken, TokenHash}

  @failure "Ticket PDF is not available for download."
  @sensitive_values [
    "https://checkout.paystack.test/pay/order-show-secret",
    "provider_payload_secret",
    "buyer@example.test",
    "+27821234567"
  ]

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

  describe "GET /t/:token/pdf" do
    test "downloads a current PDF without exposing secrets or mutating ticket state" do
      %{
        token: token,
        delivery_hash: delivery_hash,
        qr_hash: qr_hash,
        ticket_code: ticket_code,
        ticket_issue_id: ticket_issue_id,
        attendee: attendee,
        order_id: order_id
      } = issued_ticket_fixture()

      snapshot_before = data_snapshot(ticket_issue_id, attendee.id, order_id)
      conn = get_pdf(token)

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"

      assert get_resp_header(conn, "content-disposition") == [
               "attachment; filename=\"fastcheck-ticket.pdf\""
             ]

      assert get_resp_header(conn, "cache-control") == ["no-store, private"]
      assert get_resp_header(conn, "pragma") == ["no-cache"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert String.starts_with?(conn.resp_body, "%PDF-")
      assert conn.resp_body =~ "% FastCheck QR matrix modules="
      assert conn.resp_body =~ "Ticket code: #{ticket_code}"

      response_text = response_text(conn)

      for value <- [token, delivery_hash, qr_hash | @sensitive_values] do
        refute response_text =~ value
      end

      assert data_snapshot(ticket_issue_id, attendee.id, order_id) == snapshot_before
    end

    test "malformed and unknown tokens return generic non-PDF failures" do
      unknown_token = DeliveryToken.generate().token

      assert_denied("bad token", 404, ["bad token"])
      assert_denied(unknown_token, 404, [unknown_token])
    end

    test "expired delivery token returns a generic non-PDF failure" do
      %{token: token, delivery_hash: delivery_hash} =
        issued_ticket_fixture(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))

      assert_denied(token, 410, [token, delivery_hash | @sensitive_values])
    end

    test "revoked ticket returns a generic non-PDF failure" do
      %{token: token, delivery_hash: delivery_hash, qr_hash: qr_hash, ticket_code: ticket_code} =
        issued_ticket_fixture(status: "revoked", revoked_at: DateTime.utc_now())

      assert_denied(token, 410, [token, delivery_hash, qr_hash, ticket_code | @sensitive_values])
    end

    test "archived event returns a generic non-PDF failure" do
      %{token: token, event: event} = issued_ticket_fixture()

      event
      |> Event.changeset(%{status: "archived"})
      |> Repo.update!()

      assert_denied(token, 409, [token | @sensitive_values])
    end

    test "not-scannable attendee returns a generic non-PDF failure" do
      %{token: token, attendee: attendee} = issued_ticket_fixture()

      attendee
      |> Attendee.changeset(%{scan_eligibility: "not_scannable"})
      |> Repo.update!()

      assert_denied(token, 409, [token | @sensitive_values])
    end

    test "ticket that is not ready returns a generic non-PDF failure" do
      %{token: token} = issued_ticket_fixture(status: "pending")

      assert_denied(token, 409, [token | @sensitive_values])
    end

    test "renderer failure returns a generic non-PDF failure" do
      %{token: token, ticket_issue_id: ticket_issue_id, ticket_code: ticket_code} =
        issued_ticket_fixture()

      Repo.query!("UPDATE sales_ticket_issues SET ticket_code = $1 WHERE id = $2", [
        ticket_code <> "\nBAD",
        ticket_issue_id
      ])

      assert_denied(token, 500, [token, ticket_code | @sensitive_values])
    end

    test "a ticket revoked after page load cannot download a PDF" do
      %{token: token, ticket_issue_id: ticket_issue_id} = issued_ticket_fixture()

      page = get(build_conn(), "/t/#{token}")

      assert page.status == 200
      assert page.resp_body =~ "Download PDF"
      assert page.resp_body =~ ~s(href="/t/#{token}/pdf")

      Repo.query!(
        "UPDATE sales_ticket_issues SET status = 'revoked', revoked_at = now() WHERE id = $1",
        [
          ticket_issue_id
        ]
      )

      assert_denied(token, 410, [token])
    end
  end

  defp assert_denied(token, status, sensitive_values) do
    conn = get_pdf(token)

    assert conn.status == status
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/plain"
    assert conn.resp_body == @failure
    refute String.starts_with?(conn.resp_body, "%PDF-")

    response_text = response_text(conn)

    Enum.each(sensitive_values, fn value ->
      refute response_text =~ value
    end)
  end

  defp get_pdf(token), do: get(build_conn(), "/t/#{token}/pdf")

  defp response_text(conn) do
    headers = Enum.map_join(conn.resp_headers, "\n", fn {name, value} -> "#{name}: #{value}" end)
    "#{conn.resp_body}\n#{headers}"
  end

  defp data_snapshot(ticket_issue_id, attendee_id, order_id) do
    %{
      ticket_issue:
        Repo.one!(
          from t in "sales_ticket_issues",
            where: t.id == ^ticket_issue_id,
            select: %{
              status: t.status,
              scanner_status: t.scanner_status,
              revoked_at: t.revoked_at,
              delivery_token_hash: t.delivery_token_hash,
              delivery_token_expires_at: t.delivery_token_expires_at,
              attendee_id: t.attendee_id,
              sales_order_id: t.sales_order_id
            }
        ),
      attendee:
        Repo.one!(
          from a in "attendees",
            where: a.id == ^attendee_id,
            select: %{
              scan_eligibility: a.scan_eligibility,
              payment_status: a.payment_status,
              sales_ticket_issue_id: a.sales_ticket_issue_id,
              checked_in_at: a.checked_in_at,
              checked_out_at: a.checked_out_at,
              last_checked_in_at: a.last_checked_in_at,
              is_currently_inside: a.is_currently_inside
            }
        ),
      order:
        Repo.one!(
          from o in "sales_orders",
            where: o.id == ^order_id,
            select: %{status: o.status, event_id: o.event_id, updated_at: o.updated_at}
        ),
      payment_attempts:
        Repo.query!("SELECT to_jsonb(p) FROM sales_payment_attempts AS p ORDER BY p.id").rows,
      delivery_attempts:
        Repo.query!("SELECT to_jsonb(d) FROM sales_delivery_attempts AS d ORDER BY d.id").rows
    }
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
