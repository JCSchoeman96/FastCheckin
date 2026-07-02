defmodule FastCheck.TicketResendFixtures do
  @moduledoc false

  import Ecto.Query

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Fixtures
  alias FastCheck.Repo
  alias FastCheck.Tickets.Resend.Hash

  def issued_ticket_candidate!(opts \\ []) do
    event = Fixtures.create_event(%{status: Keyword.get(opts, :event_status, "active")})
    unique = System.unique_integer([:positive])
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    offer_id =
      Repo.one!(
        from o in "sales_ticket_offers",
          where: o.id == ^insert_offer!(event.id, unique, now),
          select: o.id
      )

    order_id = insert_order!(event.id, unique, now, opts)
    line_id = insert_order_line!(order_id, offer_id, event.name, now)

    attendee =
      Fixtures.create_attendee(event, %{
        first_name: Keyword.get(opts, :attendee_first_name, "Jamie"),
        last_name: Keyword.get(opts, :attendee_last_name, "Smith"),
        email: Keyword.get(opts, :attendee_email, "jamie@example.com"),
        ticket_code: Keyword.get(opts, :ticket_code, "RS-#{unique}"),
        payment_status: Keyword.get(opts, :payment_status, "completed"),
        scan_eligibility: Keyword.get(opts, :scan_eligibility, "active"),
        sales_order_id: order_id
      })

    ticket_issue_id = insert_ticket_issue!(order_id, line_id, attendee.id, unique, now, opts)

    attendee
    |> Attendee.changeset(%{sales_ticket_issue_id: ticket_issue_id})
    |> Repo.update!()

    %{
      event: event,
      sales_order_id: order_id,
      order_id: order_id,
      ticket_issue_id: ticket_issue_id,
      attendee: Repo.get!(Attendee, attendee.id),
      ticket_code: Keyword.get(opts, :ticket_code, "RS-#{unique}"),
      buyer_email: Keyword.get(opts, :buyer_email, "resend@example.com"),
      buyer_name: Keyword.get(opts, :buyer_name, "Jamie Smith")
    }
  end

  def challenge_attrs!(opts \\ []) do
    candidate = issued_ticket_candidate!(opts)
    email = Keyword.get(opts, :normalized_email, "resend@example.com")
    name = Keyword.get(opts, :normalized_name, "jamie smith")

    %{
      sales_order_id: candidate.sales_order_id,
      ticket_issue_id: candidate.ticket_issue_id,
      conversation_id: Keyword.get(opts, :conversation_id),
      request_email_hash: Hash.email(email),
      request_name_hash: Hash.name(name),
      source_hash: Hash.source(%{conversation_id: Keyword.get(opts, :conversation_id, 123)}),
      candidate_hash: Hash.candidate(candidate.sales_order_id, candidate.ticket_issue_id),
      metadata: %{
        source: "ticket_resend",
        sales_order_id: candidate.sales_order_id,
        ticket_issue_id: candidate.ticket_issue_id,
        event_id: candidate.event.id,
        buyer_email: candidate.buyer_email,
        buyer_name: candidate.buyer_name
      }
    }
  end

  def row_snapshot(order_id, ticket_issue_id, attendee_id) do
    %{
      order:
        Repo.one!(
          from o in "sales_orders",
            where: o.id == ^order_id,
            select: map(o, [:id, :status, :buyer_email, :buyer_name, :updated_at])
        ),
      ticket_issue:
        Repo.one!(
          from t in "sales_ticket_issues",
            where: t.id == ^ticket_issue_id,
            select:
              map(t, [
                :id,
                :status,
                :scanner_status,
                :delivery_token_hash,
                :delivery_token_expires_at,
                :updated_at
              ])
        ),
      attendee:
        Repo.one!(
          from a in "attendees",
            where: a.id == ^attendee_id,
            select: map(a, [:id, :payment_status, :scan_eligibility, :updated_at])
        ),
      delivery_attempts:
        Repo.one!(
          from d in "sales_delivery_attempts",
            where: d.sales_order_id == ^order_id,
            select: count(d.id)
        ),
      payment_attempts:
        Repo.one!(
          from p in "sales_payment_attempts",
            where: p.sales_order_id == ^order_id,
            select: count(p.id)
        )
    }
  end

  def count_challenges do
    Repo.one!(from c in "sales_ticket_resend_challenges", select: count(c.id))
  end

  defp insert_offer!(event_id, unique, now) do
    Repo.query!(
      """
      INSERT INTO sales_ticket_offers
        (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
         initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
         inserted_at, updated_at)
      VALUES
        ($1, $2, 'General Admission', 100, 'ZAR', 100, 100, 5, true, 'whatsapp',
         $3, $4, $5, $5)
      RETURNING id
      """,
      [
        event_id,
        "Resend Offer #{unique}",
        DateTime.add(now, -3600, :second),
        DateTime.add(now, 3600, :second),
        now
      ]
    ).rows
    |> hd()
    |> hd()
  end

  defp insert_order!(event_id, unique, now, opts) do
    Repo.query!(
      """
      INSERT INTO sales_orders
        (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
         status, total_amount_cents, currency, ticket_issued_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, '+27821234567', $4, 'whatsapp', $5, 100, 'ZAR', $6, $6, $6)
      RETURNING id
      """,
      [
        "RS-ORDER-#{unique}",
        event_id,
        Keyword.get(opts, :buyer_name, "Jamie Smith"),
        Keyword.get(opts, :buyer_email, "resend@example.com"),
        Keyword.get(opts, :order_status, "ticket_issued"),
        now
      ]
    ).rows
    |> hd()
    |> hd()
  end

  defp insert_order_line!(order_id, offer_id, event_name, now) do
    Repo.query!(
      """
      INSERT INTO sales_order_lines
        (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
         event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
         metadata, inserted_at, updated_at)
      VALUES ($1, $2, 1, 'General Admission', 'General Admission', $3, 1, 100, 100, 'ZAR',
              '{}', $4, $4)
      RETURNING id
      """,
      [order_id, offer_id, event_name, now]
    ).rows
    |> hd()
    |> hd()
  end

  defp insert_ticket_issue!(order_id, line_id, attendee_id, unique, now, opts) do
    Repo.query!(
      """
      INSERT INTO sales_ticket_issues
        (sales_order_id, sales_order_line_id, line_item_sequence, attendee_id, ticket_code,
         qr_token_hash, delivery_token_hash, delivery_token_expires_at, status, scanner_status,
         issued_at, revoked_at, inserted_at, updated_at)
      VALUES ($1, $2, 1, $3, $4, $5, $6, $7, $8, $9, $10, $11, $10, $10)
      RETURNING id
      """,
      [
        order_id,
        line_id,
        attendee_id,
        Keyword.get(opts, :ticket_code, "RS-#{unique}"),
        "qr-hash-#{unique}",
        "delivery-hash-#{unique}",
        Keyword.get(opts, :delivery_token_expires_at, DateTime.add(now, 3600, :second)),
        Keyword.get(opts, :ticket_status, "issued"),
        Keyword.get(opts, :scanner_status, "valid"),
        now,
        Keyword.get(opts, :revoked_at)
      ]
    ).rows
    |> hd()
    |> hd()
  end
end
