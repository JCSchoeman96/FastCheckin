defmodule FastCheck.Sales.TicketPageTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias Ash.Changeset
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event
  alias FastCheck.Fixtures
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Sales.TicketPage
  alias FastCheck.Tickets.{DeliveryToken, QrPayload, TokenHash}

  describe "resolve/1" do
    test "valid token returns safe fields and scanner-compatible qr_payload" do
      %{token: token, ticket_code: ticket_code, event: event, attendee: attendee} =
        issued_ticket_fixture()

      result = TicketPage.resolve(token)

      assert result.state == :valid
      assert result.event_name == event.name
      assert result.attendee_name == "#{attendee.first_name} #{attendee.last_name}"
      assert result.ticket_type == attendee.ticket_type
      assert result.qr_payload == QrPayload.build_for_scanner(ticket_code)
      refute Map.has_key?(result, :ticket_code)
      refute_sensitive_fields(result)
    end

    test "raw delivery token is not stored on TicketIssue" do
      %{token: token, ticket_issue_id: ticket_issue_id} = issued_ticket_fixture()

      assert TicketPage.resolve(token).state == :valid

      row =
        Repo.one!(
          from t in "sales_ticket_issues",
            where: t.id == ^ticket_issue_id,
            select: map(t, [:delivery_token_hash, :qr_token_hash, :ticket_code])
        )

      refute Map.has_key?(row, :delivery_token)
      assert row.delivery_token_hash
      refute row.delivery_token_hash == token
      refute TokenHash.verify(token, row.delivery_token_hash, :qr)
    end

    test "unknown token returns not_found" do
      token = DeliveryToken.generate().token

      result = TicketPage.resolve(token)

      assert result.state == :not_found
      assert result.qr_payload == nil
      refute_sensitive_fields(result)
    end

    test "malformed token returns not_found without ticket issue lookup" do
      result = TicketPage.resolve("!!!")

      assert result.state == :not_found
      assert result.qr_payload == nil
    end

    test "blank token returns not_found" do
      assert TicketPage.resolve("").state == :not_found
      assert TicketPage.resolve("   ").state == :not_found
    end

    test "expired delivery token returns expired_link without payload" do
      %{token: token, ticket_issue_id: ticket_issue_id} =
        issued_ticket_fixture(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))

      result = TicketPage.resolve(token)

      assert result.state == :expired_link
      assert result.qr_payload == nil

      row = Repo.get!(TicketIssue, ticket_issue_id)
      refute row.delivery_token_hash == token
    end

    test "revoked ticket issue returns ticket_revoked without payload" do
      %{token: token} = issued_ticket_fixture(status: "revoked", revoked_at: DateTime.utc_now())

      result = TicketPage.resolve(token)

      assert result.state == :ticket_revoked
      assert result.qr_payload == nil
    end

    test "pending ticket issue returns ticket_not_ready without payload" do
      %{token: token} = issued_ticket_fixture(status: "pending")

      result = TicketPage.resolve(token)

      assert result.state == :ticket_not_ready
      assert result.qr_payload == nil
    end

    test "missing attendee returns ticket_not_ready without crash" do
      %{token: token, ticket_issue_id: ticket_issue_id} = issued_ticket_fixture()

      Repo.query!("UPDATE sales_ticket_issues SET attendee_id = $1 WHERE id = $2", [
        999_999_999,
        ticket_issue_id
      ])

      result = TicketPage.resolve(token)

      assert result.state == :ticket_not_ready
      assert result.qr_payload == nil
    end

    test "missing event returns ticket_not_ready without crash" do
      %{token: token, order_id: order_id} = issued_ticket_fixture()

      Repo.query!("UPDATE sales_orders SET event_id = $1 WHERE id = $2", [999_999_999, order_id])

      result = TicketPage.resolve(token)

      assert result.state == :ticket_not_ready
      assert result.qr_payload == nil
    end

    test "archived event returns ticket_not_ready without payload" do
      %{token: token, event: event} = issued_ticket_fixture()

      event
      |> Event.changeset(%{status: "archived"})
      |> Repo.update!()

      result = TicketPage.resolve(token)

      assert result.state == :ticket_not_ready
      assert result.qr_payload == nil
    end

    test "not_scannable attendee returns ticket_not_scannable without payload" do
      %{token: token, attendee: attendee} = issued_ticket_fixture()

      attendee
      |> Attendee.changeset(%{scan_eligibility: "not_scannable"})
      |> Repo.update!()

      result = TicketPage.resolve(token)

      assert result.state == :ticket_not_scannable
      assert result.qr_payload == nil
    end

    test "non-completed payment_status returns ticket_not_scannable without payload" do
      %{token: token, attendee: attendee} = issued_ticket_fixture()

      attendee
      |> Attendee.changeset(%{payment_status: "pending"})
      |> Repo.update!()

      result = TicketPage.resolve(token)

      assert result.state == :ticket_not_scannable
      assert result.qr_payload == nil
    end
  end

  defp issued_ticket_fixture(opts \\ []) do
    event = Fixtures.create_event()
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
        [event_id, "Ticket Page Offer #{System.unique_integer([:positive])}"]
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
        ["FC-TP-#{System.unique_integer([:positive])}", event_id]
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

  defp system_actor, do: %{actor_type: :system, actor_id: "ticket_page_test"}

  defp refute_sensitive_fields(result) do
    encoded = Jason.encode!(result)

    refute encoded =~ "delivery_token"
    refute encoded =~ "delivery_token_hash"
    refute encoded =~ "qr_token"
    refute encoded =~ "buyer_phone"
    refute encoded =~ "buyer_email"
    refute encoded =~ "paystack"
    refute encoded =~ "provider"
  end
end
