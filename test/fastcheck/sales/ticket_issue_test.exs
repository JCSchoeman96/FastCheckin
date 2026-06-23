defmodule FastCheck.Sales.TicketIssueTest do
  use FastCheck.DataCase, async: true

  import Ecto.Query

  alias Ash.Changeset
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketIssue

  test "create_issued_link writes safe TicketIssue state transition metadata" do
    {order_id, order_line_id} = insert_order_with_line!()

    attrs = %{
      sales_order_id: order_id,
      sales_order_line_id: order_line_id,
      line_item_sequence: 1,
      attendee_id: 42_001,
      ticket_code: "FC-SECRET-CODE",
      qr_token_hash: "qr-secret-hash",
      delivery_token_hash: "delivery-secret-hash",
      delivery_token_expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
    }

    assert {:ok, ticket_issue} =
             TicketIssue
             |> Changeset.for_create(:create_issued_link, attrs, actor: system_actor())
             |> Ash.create(authorize?: false)

    assert ticket_issue.status == "issued"
    assert ticket_issue.scanner_status == "valid"

    transition = ticket_issue_transition!(ticket_issue.id)
    assert transition.entity_type == "TicketIssue"
    assert transition.from_state == nil
    assert transition.to_state == "issued"
    assert transition.source == "ticket_issue.create_issued_link"

    assert transition.metadata["sales_order_id"] == order_id
    assert transition.metadata["sales_order_line_id"] == order_line_id
    assert transition.metadata["line_item_sequence"] == 1
    assert transition.metadata["reason_code"] == "issuer_ticket_issue_linked"

    refute Map.has_key?(transition.metadata, "ticket_code")
    refute Map.has_key?(transition.metadata, "qr_token")
    refute Map.has_key?(transition.metadata, "qr_token_hash")
    refute Map.has_key?(transition.metadata, "delivery_token")
    refute Map.has_key?(transition.metadata, "delivery_token_hash")
    refute Map.has_key?(transition.metadata, "buyer_email")
    refute Map.has_key?(transition.metadata, "buyer_phone")
    refute Map.has_key?(transition.metadata, "raw_payload")
  end

  test "mark_revoked writes safe TicketIssue state transition metadata" do
    {order_id, order_line_id} = insert_order_with_line!()

    attrs = %{
      sales_order_id: order_id,
      sales_order_line_id: order_line_id,
      line_item_sequence: 1,
      attendee_id: 42_002,
      ticket_code: "FC-REVOKE-CODE",
      qr_token_hash: "qr-revoke-hash",
      delivery_token_hash: "delivery-revoke-hash",
      delivery_token_expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
    }

    assert {:ok, ticket_issue} =
             TicketIssue
             |> Changeset.for_create(:create_issued_link, attrs, actor: system_actor())
             |> Ash.create(authorize?: false)

    assert {:ok, revoked} =
             ticket_issue
             |> Changeset.for_update(
               :mark_revoked,
               %{revocation_reason: "sales_refund"},
               actor: system_actor()
             )
             |> Ash.update(authorize?: false)

    assert revoked.status == "revoked"
    assert revoked.revoked_at
    assert revoked.revocation_reason == "sales_refund"
    assert revoked.scanner_status == "revoked"
    assert revoked.delivery_token_expires_at

    transition = ticket_issue_revoked_transition!(ticket_issue.id)
    assert transition.from_state == "issued"
    assert transition.to_state == "revoked"
    assert transition.source == "ticket_issue.mark_revoked"
    refute Map.has_key?(transition.metadata, "ticket_code")
    refute Map.has_key?(transition.metadata, "delivery_token_hash")
  end

  defp insert_order_with_line! do
    offer_id = insert_ticket_offer!()
    order_id = insert_order!()

    %{rows: [[order_line_id]]} =
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

    {order_id, order_line_id}
  end

  defp insert_ticket_offer! do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
           lock_version, inserted_at, updated_at)
        VALUES
          (1, $1, 'general', 100, 'ZAR', 10, 10, 5, true, 'whatsapp',
           now(), now() + interval '1 day', 1, now(), now())
        RETURNING id
        """,
        ["TicketIssue Test Offer #{System.unique_integer([:positive])}"]
      )

    id
  end

  defp insert_order! do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, source_channel, status, total_amount_cents,
           currency, inserted_at, updated_at)
        VALUES
          ($1, 1, 'Buyer', 'whatsapp', 'draft', 100, 'ZAR', now(), now())
        RETURNING id
        """,
        ["FC-TI-#{System.unique_integer([:positive])}"]
      )

    id
  end

  defp ticket_issue_transition!(ticket_issue_id) do
    Repo.one!(
      from st in "sales_state_transitions",
        where:
          st.entity_type == "TicketIssue" and
            st.entity_id == ^Integer.to_string(ticket_issue_id) and
            st.to_state == "issued",
        select: %{
          entity_type: st.entity_type,
          from_state: st.from_state,
          to_state: st.to_state,
          source: st.source,
          metadata: st.metadata
        }
    )
  end

  defp ticket_issue_revoked_transition!(ticket_issue_id) do
    Repo.one!(
      from st in "sales_state_transitions",
        where:
          st.entity_type == "TicketIssue" and
            st.entity_id == ^Integer.to_string(ticket_issue_id) and
            st.to_state == "revoked",
        select: %{
          from_state: st.from_state,
          to_state: st.to_state,
          source: st.source,
          metadata: st.metadata
        }
    )
  end

  defp system_actor do
    %{actor_type: :system, actor_id: "system"}
  end
end
