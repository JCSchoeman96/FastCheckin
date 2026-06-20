defmodule FastCheck.Attendees.OriginProtectionTest do
  @moduledoc """
  Verifies VS-02 attendee origin protections for Tickera sync and reconciliation.
  """
  use FastCheck.DataCase, async: true

  import Ecto.Query
  import FastCheck.Fixtures

  alias FastCheck.Attendees

  alias FastCheck.Attendees.{
    Attendee,
    AttendeeInvalidationEvent,
    ReasonCodes,
    Reconciliation,
    Scan
  }

  alias FastCheck.Repo

  describe "attendee origin fields and constraints" do
    test "source defaults to tickera for newly inserted attendees" do
      event = create_event()
      attendee = create_attendee(event, %{})

      assert attendee.source == "tickera"
    end

    test "invalid source is rejected by attendees_source_valid" do
      event = create_event()

      changeset =
        Attendee.changeset(%Attendee{}, attendee_params(event, %{source: "unknown_origin"}))

      assert {:error, failed_changeset} = Repo.insert(changeset)

      assert {"is invalid", [constraint: :check, constraint_name: "attendees_source_valid"]} =
               failed_changeset.errors[:source]
    end

    test "duplicate non-null sales_ticket_issue_id is rejected" do
      event = create_event()
      _first = create_attendee(event, %{sales_ticket_issue_id: 314})

      changeset =
        Attendee.changeset(%Attendee{}, attendee_params(event, %{sales_ticket_issue_id: 314}))

      assert {:error, failed_changeset} = Repo.insert(changeset)

      assert {"has already been taken",
              [constraint: :unique, constraint_name: "attendees_sales_ticket_issue_id_uidx"]} =
               failed_changeset.errors[:sales_ticket_issue_id]
    end

    test "duplicate fastcheck_sales source_reference is rejected by database constraint" do
      event = create_event()
      source_reference = "sales:#{System.unique_integer([:positive])}:10:1"

      _first =
        create_attendee(event, %{
          ticket_code: "SALES-SRC-1",
          source: "fastcheck_sales",
          source_reference: source_reference
        })

      changeset =
        Attendee.changeset(
          %Attendee{},
          attendee_params(event, %{
            ticket_code: "SALES-SRC-2",
            source: "fastcheck_sales",
            source_reference: source_reference
          })
        )

      assert {:error, failed_changeset} = Repo.insert(changeset)

      assert {"has already been taken",
              [
                constraint: :unique,
                constraint_name: "attendees_fastcheck_sales_source_reference_uidx"
              ]} = failed_changeset.errors[:source_reference]
    end

    test "duplicate source_reference outside fastcheck_sales follows existing non-unique behavior" do
      event = create_event()
      source_reference = "manual-ref-#{System.unique_integer([:positive])}"

      first =
        create_attendee(event, %{
          ticket_code: "MANUAL-SRC-1",
          source: "manual",
          source_reference: source_reference
        })

      second =
        create_attendee(event, %{
          ticket_code: "MANUAL-SRC-2",
          source: "manual",
          source_reference: source_reference
        })

      assert first.source_reference == second.source_reference
    end
  end

  describe "tickera upsert ownership protection" do
    test "create_bulk does not overwrite fastcheck_sales attendee on event_id+ticket_code conflict" do
      event = create_event()

      _sales_attendee =
        create_attendee(event, %{
          ticket_code: "SALES-LOCK-1",
          source: "fastcheck_sales",
          source_reference: "order:42",
          first_name: "Original",
          email: "original@fastcheck.example.com",
          scan_eligibility: "not_scannable",
          ineligibility_reason: ReasonCodes.revoked(),
          sales_order_id: 42,
          sales_ticket_issue_id: 4200,
          revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
          revocation_reason: "support_revoke"
        })

      remote_rows = [tickera_row("SALES-LOCK-1", "Remote", "remote@tickera.example.com")]

      assert {:ok, 0} = Attendees.create_bulk(event.id, remote_rows, incremental: true)

      attendee = Repo.get_by!(Attendee, event_id: event.id, ticket_code: "SALES-LOCK-1")
      assert attendee.source == "fastcheck_sales"
      assert attendee.source_reference == "order:42"
      assert attendee.first_name == "Original"
      assert attendee.email == "original@fastcheck.example.com"
      assert attendee.scan_eligibility == "not_scannable"
      assert attendee.ineligibility_reason == ReasonCodes.revoked()
      assert attendee.sales_order_id == 42
      assert attendee.sales_ticket_issue_id == 4200
      assert attendee.revocation_reason == "support_revoke"
      assert attendee.revoked_at
    end
  end

  describe "authoritative reconciliation source scoping" do
    test "reconciliation keeps fastcheck_sales attendee active when absent from Tickera snapshot" do
      event = create_event()

      sales_attendee =
        create_attendee(event, %{
          ticket_code: "SALES-STAY-1",
          source: "fastcheck_sales",
          scan_eligibility: "active"
        })

      sync_run = Ecto.UUID.generate()

      Repo.transaction(fn ->
        assert :ok == Reconciliation.apply_after_authoritative_snapshot(event.id, [], sync_run)
      end)

      attendee = Repo.get!(Attendee, sales_attendee.id)
      assert attendee.scan_eligibility == "active"
      assert attendee.ineligibility_reason == nil

      refute Repo.exists?(
               from(i in AttendeeInvalidationEvent,
                 where: i.event_id == ^event.id and i.attendee_id == ^sales_attendee.id
               )
             )
    end

    test "reconciliation still marks tickera attendee absent from authoritative snapshot not scannable" do
      event = create_event()

      tickera_attendee =
        create_attendee(event, %{ticket_code: "TICKERA-GONE-1", source: "tickera"})

      sync_run = Ecto.UUID.generate()

      Repo.transaction(fn ->
        assert :ok == Reconciliation.apply_after_authoritative_snapshot(event.id, [], sync_run)
      end)

      attendee = Repo.get!(Attendee, tickera_attendee.id)
      assert attendee.scan_eligibility == "not_scannable"
      assert attendee.ineligibility_reason == ReasonCodes.source_missing_from_authoritative_sync()

      assert Repo.exists?(
               from(i in AttendeeInvalidationEvent,
                 where: i.event_id == ^event.id and i.attendee_id == ^tickera_attendee.id
               )
             )
    end
  end

  describe "scanner behavior compatibility" do
    test "scan check-in rejects revoked fastcheck_sales attendee using existing scan_eligibility truth" do
      event = create_event()

      _attendee =
        create_attendee(event, %{
          ticket_code: "SALES-REVOKED-1",
          source: "fastcheck_sales",
          scan_eligibility: "not_scannable",
          ineligibility_reason: ReasonCodes.revoked()
        })

      assert {:error, "TICKET_NOT_SCANNABLE", "This ticket is no longer valid for scanning"} =
               Scan.check_in(event.id, "SALES-REVOKED-1", "Main")
    end
  end

  defp tickera_row(ticket_code, first_name, email) do
    %{
      "checksum" => ticket_code,
      "buyer_first" => first_name,
      "buyer_last" => "Tickera",
      "payment_date" => "1st Jan 2025 - 10:00 am",
      "allowed_checkins" => 1,
      "custom_fields" => [
        ["Ticket Type", "General Admission"],
        ["Buyer E-mail", email]
      ]
    }
  end

  defp attendee_params(event, attrs) do
    Map.merge(
      %{
        event_id: event.id,
        ticket_code: "TICKET-#{System.unique_integer([:positive])}",
        first_name: "John",
        last_name: "Doe",
        email: "john.doe@example.com",
        ticket_type: "General Admission",
        allowed_checkins: 1,
        checkins_remaining: 1,
        payment_status: "completed"
      },
      attrs
    )
  end
end
