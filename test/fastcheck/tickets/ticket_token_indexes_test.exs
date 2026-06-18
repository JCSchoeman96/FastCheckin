defmodule FastCheck.Tickets.TicketTokenIndexesTest do
  use FastCheck.DataCase, async: true

  test "VS-08 token hash and expiry indexes exist with expected predicates" do
    assert_index("sales_ticket_issues_qr_token_hash_uidx")
    assert_index_where("sales_ticket_issues_qr_token_hash_uidx", "qr_token_hash IS NOT NULL")

    assert_index("sales_ticket_issues_delivery_token_hash_uidx")

    assert_index_where(
      "sales_ticket_issues_delivery_token_hash_uidx",
      "delivery_token_hash IS NOT NULL"
    )

    assert_index("sales_ticket_issues_delivery_token_expires_at_idx")

    assert_index_where(
      "sales_ticket_issues_delivery_token_expires_at_idx",
      "delivery_token_hash IS NOT NULL"
    )

    assert_index("sales_ticket_issues_status_delivery_token_expires_at_idx")
    assert_index("sales_ticket_issues_scanner_status_idx")
    assert_index("sales_ticket_issues_ticket_code_uidx")
  end

  test "duplicate qr_token_hash values are rejected" do
    order_id = insert_order!()
    line_id = insert_order_line!(order_id)
    hash = "duplicate-qr-hash"

    insert_ticket_issue!(order_id, line_id, 1, %{qr_token_hash: hash})

    assert_raise Postgrex.Error, ~r/sales_ticket_issues_qr_token_hash_uidx/, fn ->
      insert_ticket_issue!(order_id, line_id, 2, %{qr_token_hash: hash})
    end
  end

  test "duplicate delivery_token_hash values are rejected" do
    order_id = insert_order!()
    line_id = insert_order_line!(order_id)
    hash = "duplicate-delivery-hash"

    insert_ticket_issue!(order_id, line_id, 1, %{delivery_token_hash: hash})

    assert_raise Postgrex.Error, ~r/sales_ticket_issues_delivery_token_hash_uidx/, fn ->
      insert_ticket_issue!(order_id, line_id, 2, %{delivery_token_hash: hash})
    end
  end

  defp assert_index(index_name) do
    assert [[^index_name]] =
             Repo.query!(
               """
               SELECT indexname
               FROM pg_indexes
               WHERE schemaname = 'public' AND indexname = $1
               """,
               [index_name]
             ).rows
  end

  defp assert_index_where(index_name, expected_where) do
    assert [[indexdef]] =
             Repo.query!(
               """
               SELECT indexdef
               FROM pg_indexes
               WHERE schemaname = 'public' AND indexname = $1
               """,
               [index_name]
             ).rows

    assert indexdef =~ expected_where
  end

  defp insert_order! do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, source_channel, status,
           total_amount_cents, currency, inserted_at, updated_at)
        VALUES
          ($1, 1, 'Buyer', '+27820000000', 'whatsapp', 'draft', 100, 'ZAR', now(), now())
        RETURNING id
        """,
        ["FC-VS08-#{System.unique_integer([:positive])}"]
      ).rows

    id
  end

  defp insert_order_line!(order_id) do
    offer_id = insert_ticket_offer!()

    [[id]] =
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
      ).rows

    id
  end

  defp insert_ticket_offer! do
    [[id]] =
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
        ["VS08 Offer #{System.unique_integer([:positive])}"]
      ).rows

    id
  end

  defp insert_ticket_issue!(order_id, line_id, sequence, attrs) do
    qr_token_hash = Map.get(attrs, :qr_token_hash)
    delivery_token_hash = Map.get(attrs, :delivery_token_hash)

    Repo.query!(
      """
      INSERT INTO sales_ticket_issues
        (sales_order_id, sales_order_line_id, line_item_sequence, status,
         qr_token_hash, delivery_token_hash, inserted_at, updated_at)
      VALUES
        ($1, $2, $3, 'pending', $4, $5, now(), now())
      """,
      [order_id, line_id, sequence, qr_token_hash, delivery_token_hash]
    )
  end
end
