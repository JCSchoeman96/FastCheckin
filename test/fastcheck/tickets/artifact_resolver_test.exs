defmodule FastCheck.Tickets.ArtifactResolverTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias Ash.Changeset
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event
  alias FastCheck.Fixtures
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Tickets.Artifact
  alias FastCheck.Tickets.ArtifactError
  alias FastCheck.Tickets.ArtifactResolver
  alias FastCheck.Tickets.DeliveryToken
  alias FastCheck.Tickets.QrPayload
  alias FastCheck.Tickets.TokenHash

  describe "resolve_from_delivery_token/1" do
    test "valid token returns a safe artifact with scanner payload available as data" do
      %{
        token: token,
        delivery_hash: delivery_hash,
        qr_hash: qr_hash,
        ticket_code: ticket_code,
        ticket_issue_id: ticket_issue_id,
        event: event,
        attendee: attendee
      } = issued_ticket_fixture()

      assert {:ok, %Artifact{} = artifact} = ArtifactResolver.resolve_from_delivery_token(token)

      assert artifact.state == :valid
      assert artifact.event_name == event.name
      assert artifact.attendee_name == "#{attendee.first_name} #{attendee.last_name}"
      assert artifact.ticket_type == attendee.ticket_type
      assert artifact.scanner_payload == QrPayload.build_for_scanner(ticket_code)
      assert artifact.scanner_payload_format == :plain_ticket_code
      assert artifact.support_message == "Present this ticket code at the entrance scanner."
      assert artifact.issued_at
      assert artifact.delivery_expires_at

      assert Map.keys(Map.from_struct(artifact)) |> Enum.sort() == [
               :attendee_name,
               :delivery_expires_at,
               :event_name,
               :issued_at,
               :scanner_payload,
               :scanner_payload_format,
               :state,
               :support_message,
               :ticket_type
             ]

      inspected = inspect(artifact)

      refute inspected =~ artifact.scanner_payload
      refute inspected =~ ticket_code
      refute inspected =~ token
      refute inspected =~ delivery_hash
      refute inspected =~ qr_hash
      refute inspected =~ Integer.to_string(ticket_issue_id)
      refute inspected =~ Integer.to_string(attendee.id)
      refute inspected =~ attendee.email
      refute inspected =~ event.name
      refute inspected =~ "http"
      assert inspected =~ "[REDACTED]"
    end

    test "malformed token returns not_found error" do
      assert {:error, %ArtifactError{state: :not_found} = error} =
               ArtifactResolver.resolve_from_delivery_token("!!!")

      refute_error_inspect_leaks(error, ["!!!"])
    end

    test "non-binary token returns not_found error" do
      assert {:error, %ArtifactError{state: :not_found}} =
               ArtifactResolver.resolve_from_delivery_token(nil)
    end

    test "unknown valid-format token returns not_found error" do
      token = DeliveryToken.generate().token

      assert {:error, %ArtifactError{state: :not_found} = error} =
               ArtifactResolver.resolve_from_delivery_token(token)

      refute_error_inspect_leaks(error, [token])
    end

    test "expired token returns expired_link without payload" do
      %{token: token, ticket_code: ticket_code, delivery_hash: delivery_hash, qr_hash: qr_hash} =
        issued_ticket_fixture(expires_at: DateTime.add(DateTime.utc_now(), -3600, :second))

      assert {:error, %ArtifactError{state: :expired_link} = error} =
               ArtifactResolver.resolve_from_delivery_token(token)

      assert error.http_status_hint == :gone
      refute_error_inspect_leaks(error, [token, ticket_code, delivery_hash, qr_hash])
    end

    test "revoked ticket issue returns ticket_revoked without payload" do
      %{token: token, ticket_code: ticket_code} =
        issued_ticket_fixture(status: "revoked", revoked_at: DateTime.utc_now())

      assert {:error, %ArtifactError{state: :ticket_revoked} = error} =
               ArtifactResolver.resolve_from_delivery_token(token)

      assert error.http_status_hint == :ok
      refute_error_inspect_leaks(error, [token, ticket_code])
    end

    test "non-issued ticket issue returns ticket_not_ready without payload" do
      %{token: token, ticket_code: ticket_code} = issued_ticket_fixture(status: "pending")

      assert {:error, %ArtifactError{state: :ticket_not_ready} = error} =
               ArtifactResolver.resolve_from_delivery_token(token)

      refute_error_inspect_leaks(error, [token, ticket_code])
    end

    test "missing attendee returns ticket_not_ready without payload" do
      %{token: token, ticket_issue_id: ticket_issue_id, ticket_code: ticket_code} =
        issued_ticket_fixture()

      Repo.query!("UPDATE sales_ticket_issues SET attendee_id = $1 WHERE id = $2", [
        999_999_999,
        ticket_issue_id
      ])

      assert {:error, %ArtifactError{state: :ticket_not_ready} = error} =
               ArtifactResolver.resolve_from_delivery_token(token)

      refute_error_inspect_leaks(error, [token, ticket_code])
    end

    test "missing event returns ticket_not_ready without payload" do
      %{token: token, order_id: order_id, ticket_code: ticket_code} = issued_ticket_fixture()

      Repo.query!("UPDATE sales_orders SET event_id = $1 WHERE id = $2", [999_999_999, order_id])

      assert {:error, %ArtifactError{state: :ticket_not_ready} = error} =
               ArtifactResolver.resolve_from_delivery_token(token)

      refute_error_inspect_leaks(error, [token, ticket_code])
    end

    test "archived event returns ticket_not_ready without payload" do
      %{token: token, event: event, ticket_code: ticket_code} = issued_ticket_fixture()

      event
      |> Event.changeset(%{status: "archived"})
      |> Repo.update!()

      assert {:error, %ArtifactError{state: :ticket_not_ready} = error} =
               ArtifactResolver.resolve_from_delivery_token(token)

      refute_error_inspect_leaks(error, [token, ticket_code])
    end

    test "not-scannable attendee returns ticket_not_scannable without payload" do
      %{token: token, attendee: attendee, ticket_code: ticket_code} = issued_ticket_fixture()

      attendee
      |> Attendee.changeset(%{scan_eligibility: "not_scannable"})
      |> Repo.update!()

      assert {:error, %ArtifactError{state: :ticket_not_scannable} = error} =
               ArtifactResolver.resolve_from_delivery_token(token)

      refute_error_inspect_leaks(error, [token, ticket_code])
    end

    test "unacceptable payment status returns ticket_not_scannable without payload" do
      %{token: token, attendee: attendee, ticket_code: ticket_code} = issued_ticket_fixture()

      attendee
      |> Attendee.changeset(%{payment_status: "pending"})
      |> Repo.update!()

      assert {:error, %ArtifactError{state: :ticket_not_scannable} = error} =
               ArtifactResolver.resolve_from_delivery_token(token)

      refute_error_inspect_leaks(error, [token, ticket_code])
    end

    test "resolver does not mutate ticket, attendee, order, payment, or delivery rows" do
      %{token: token, ticket_issue_id: ticket_issue_id, attendee: attendee, order_id: order_id} =
        issued_ticket_fixture()

      counts_before = row_counts(ticket_issue_id, attendee.id, order_id)

      assert {:ok, %Artifact{}} = ArtifactResolver.resolve_from_delivery_token(token)

      assert row_counts(ticket_issue_id, attendee.id, order_id) == counts_before
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
        [event_id, "Artifact Resolver Offer #{System.unique_integer([:positive])}"]
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
        ["FC-AR-#{System.unique_integer([:positive])}", event_id]
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

  defp refute_error_inspect_leaks(error, sensitive_values) do
    inspected = inspect(error)

    assert inspected =~ "state:"
    assert inspected =~ "http_status_hint:"
    refute inspected =~ error.support_message
    refute inspected =~ "scanner_payload"
    refute inspected =~ "delivery_token"
    refute inspected =~ "delivery_token_hash"
    refute inspected =~ "qr_token_hash"
    refute inspected =~ "raw_payload"
    refute inspected =~ "phone"
    refute inspected =~ "email"
    refute inspected =~ "payment"
    refute inspected =~ "ticket_url"
    refute inspected =~ "http://"
    refute inspected =~ "https://"
    refute inspected =~ "@"

    Enum.each(sensitive_values, fn value ->
      refute inspected =~ to_string(value)
    end)
  end

  defp system_actor, do: %{actor_type: :system, actor_id: "artifact_resolver_test"}
end
