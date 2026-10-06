defmodule FastCheck.Sales.TicketIssueTest do
  use FastCheck.DataCase, async: false

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

  test "create_issued_link defaults delivery_token_generation to zero" do
    {order_id, order_line_id} = insert_order_with_line!()

    assert {:ok, ticket_issue} =
             TicketIssue
             |> Changeset.for_create(
               :create_issued_link,
               issued_link_attrs(order_id, order_line_id, 42_010),
               actor: system_actor()
             )
             |> Ash.create(authorize?: false)

    assert ticket_issue.delivery_token_generation == 0
  end

  test "rotate_delivery_token_for_delivery advances generation and token fields" do
    {order_id, order_line_id} = insert_order_with_line!()

    assert {:ok, ticket_issue} =
             TicketIssue
             |> Changeset.for_create(
               :create_issued_link,
               issued_link_attrs(order_id, order_line_id, 42_011),
               actor: system_actor()
             )
             |> Ash.create(authorize?: false)

    expires_at = DateTime.utc_now() |> DateTime.add(7200, :second) |> DateTime.truncate(:second)

    assert {:ok, rotated_once} =
             ticket_issue
             |> Changeset.for_update(
               :rotate_delivery_token_for_delivery,
               %{
                 delivery_token_hash: "delivery-rotated-hash-1",
                 delivery_token_expires_at: expires_at
               },
               actor: system_actor()
             )
             |> Ash.update(authorize?: false)

    assert rotated_once.delivery_token_hash == "delivery-rotated-hash-1"
    assert rotated_once.delivery_token_expires_at == expires_at
    assert rotated_once.delivery_token_generation == 1

    later_expires =
      DateTime.utc_now() |> DateTime.add(10_800, :second) |> DateTime.truncate(:second)

    assert {:ok, rotated_twice} =
             rotated_once
             |> Changeset.for_update(
               :rotate_delivery_token_for_delivery,
               %{
                 delivery_token_hash: "delivery-rotated-hash-2",
                 delivery_token_expires_at: later_expires
               },
               actor: system_actor()
             )
             |> Ash.update(authorize?: false)

    assert rotated_twice.delivery_token_generation == 2
    assert rotated_twice.delivery_token_hash == "delivery-rotated-hash-2"
  end

  test "stale rotate_delivery_token_for_delivery cannot duplicate generation" do
    {order_id, order_line_id} = insert_order_with_line!()

    assert {:ok, ticket_issue} =
             TicketIssue
             |> Changeset.for_create(
               :create_issued_link,
               issued_link_attrs(order_id, order_line_id, 42_012),
               actor: system_actor()
             )
             |> Ash.create(authorize?: false)

    stale_copy = Ash.get!(TicketIssue, ticket_issue.id, authorize?: false)
    assert stale_copy.delivery_token_generation == 0

    expires_a = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    assert {:ok, winner} =
             stale_copy
             |> Changeset.for_update(
               :rotate_delivery_token_for_delivery,
               %{
                 delivery_token_hash: "delivery-winner-hash",
                 delivery_token_expires_at: expires_a
               },
               actor: system_actor()
             )
             |> Ash.update(authorize?: false)

    assert winner.delivery_token_generation == 1

    expires_b = DateTime.utc_now() |> DateTime.add(5400, :second) |> DateTime.truncate(:second)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             stale_copy
             |> Changeset.for_update(
               :rotate_delivery_token_for_delivery,
               %{
                 delivery_token_hash: "delivery-stale-hash",
                 delivery_token_expires_at: expires_b
               },
               actor: system_actor()
             )
             |> Ash.update(authorize?: false)

    persisted = Ash.get!(TicketIssue, ticket_issue.id, authorize?: false)
    assert persisted.delivery_token_generation == 1
    assert persisted.delivery_token_hash == "delivery-winner-hash"

    retry_copy = Ash.get!(TicketIssue, ticket_issue.id, authorize?: false)

    assert {:ok, rotated_again} =
             retry_copy
             |> Changeset.for_update(
               :rotate_delivery_token_for_delivery,
               %{
                 delivery_token_hash: "delivery-retry-hash",
                 delivery_token_expires_at: expires_b
               },
               actor: system_actor()
             )
             |> Ash.update(authorize?: false)

    assert rotated_again.delivery_token_generation == 2
  end

  test "rotate_delivery_token_for_delivery retains issued and revocation guards" do
    {order_id, order_line_id} = insert_order_with_line!()

    assert {:ok, ticket_issue} =
             TicketIssue
             |> Changeset.for_create(
               :create_issued_link,
               issued_link_attrs(order_id, order_line_id, 42_013),
               actor: system_actor()
             )
             |> Ash.create(authorize?: false)

    assert {:ok, revoked} =
             ticket_issue
             |> Changeset.for_update(
               :mark_revoked,
               %{revocation_reason: "sales_refund"},
               actor: system_actor()
             )
             |> Ash.update(authorize?: false)

    expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

    assert {:error, %Ash.Error.Invalid{}} =
             revoked
             |> Changeset.for_update(
               :rotate_delivery_token_for_delivery,
               %{
                 delivery_token_hash: "delivery-should-not-rotate",
                 delivery_token_expires_at: expires_at
               },
               actor: system_actor()
             )
             |> Ash.update(authorize?: false)
  end

  test "rotate_delivery_token_for_delivery audit transition omits token secrets" do
    {order_id, order_line_id} = insert_order_with_line!()

    assert {:ok, ticket_issue} =
             TicketIssue
             |> Changeset.for_create(
               :create_issued_link,
               issued_link_attrs(order_id, order_line_id, 42_014),
               actor: system_actor()
             )
             |> Ash.create(authorize?: false)

    expires_at = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    assert {:ok, _rotated} =
             ticket_issue
             |> Changeset.for_update(
               :rotate_delivery_token_for_delivery,
               %{
                 delivery_token_hash: "delivery-audit-hash",
                 delivery_token_expires_at: expires_at
               },
               actor: system_actor()
             )
             |> Ash.update(authorize?: false)

    transition = ticket_issue_rotation_transition!(ticket_issue.id)
    assert transition.source == "ticket_issue.rotate_delivery_token_for_delivery"
    refute Map.has_key?(transition.metadata, "delivery_token_hash")
    refute Map.has_key?(transition.metadata, "delivery_token")
    refute Map.has_key?(transition.metadata, "ticket_code")
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
    FastCheck.SalesCheckoutFixtures.ensure_event_for_sales!(1)

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
    FastCheck.SalesCheckoutFixtures.ensure_event_for_sales!(1)

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

  defp issued_link_attrs(order_id, order_line_id, attendee_id) do
    %{
      sales_order_id: order_id,
      sales_order_line_id: order_line_id,
      line_item_sequence: 1,
      attendee_id: attendee_id,
      ticket_code: "FC-#{attendee_id}",
      qr_token_hash: "qr-#{attendee_id}",
      delivery_token_hash: "delivery-#{attendee_id}",
      delivery_token_expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
    }
  end

  defp ticket_issue_rotation_transition!(ticket_issue_id) do
    Repo.one!(
      from st in "sales_state_transitions",
        where:
          st.entity_type == "TicketIssue" and
            st.entity_id == ^Integer.to_string(ticket_issue_id) and
            st.source == "ticket_issue.rotate_delivery_token_for_delivery",
        select: %{
          source: st.source,
          metadata: st.metadata
        }
    )
  end

  defp system_actor do
    %{actor_type: :system, actor_id: "system"}
  end
end
