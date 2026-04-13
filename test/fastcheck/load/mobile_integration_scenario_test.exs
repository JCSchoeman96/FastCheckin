defmodule FastCheck.Load.MobileIntegrationScenarioTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Attendees.AttendeeInvalidationEvent
  alias FastCheck.Attendees.ReasonCodes
  alias FastCheck.Crypto
  alias FastCheck.Events.Event
  alias FastCheck.Load.MobileIntegrationScenario
  alias FastCheck.Repo

  test "revoke_ticket marks attendee not_scannable, appends invalidation, and bumps version" do
    event = insert_event!()
    attendee = insert_attendee!(event.id, "SCENARIO-0001")

    assert {:ok, %{attendee: updated, changed: true}} =
             MobileIntegrationScenario.revoke_ticket(event.id, attendee.ticket_code)

    assert updated.scan_eligibility == "not_scannable"
    assert updated.ineligibility_reason == ReasonCodes.revoked()
    assert %DateTime{} = updated.ineligible_since

    invalidation =
      Repo.one!(
        from row in AttendeeInvalidationEvent,
          where: row.event_id == ^event.id and row.ticket_code == ^attendee.ticket_code,
          order_by: [desc: row.id],
          limit: 1
      )

    assert invalidation.reason_code == ReasonCodes.revoked()
    assert invalidation.change_type == "ineligible"

    refreshed_event = Repo.get!(Event, event.id)
    assert refreshed_event.event_sync_version == 1
  end

  test "set_ticket_payment_status updates payment status and bumps version once" do
    event = insert_event!()
    attendee = insert_attendee!(event.id, "SCENARIO-0002")

    assert {:ok, %{attendee: updated, changed: true}} =
             MobileIntegrationScenario.set_ticket_payment_status(
               event.id,
               attendee.ticket_code,
               "refunded"
             )

    assert updated.payment_status == "refunded"
    assert Repo.get!(Event, event.id).event_sync_version == 1

    assert {:ok, %{changed: false}} =
             MobileIntegrationScenario.set_ticket_payment_status(
               event.id,
               attendee.ticket_code,
               "refunded"
             )

    assert Repo.get!(Event, event.id).event_sync_version == 1
  end

  test "dump_ticket_state returns required harness debugging fields" do
    event = insert_event!()
    attendee = insert_attendee!(event.id, "SCENARIO-0003")

    assert {:ok, _} = MobileIntegrationScenario.revoke_ticket(event.id, attendee.ticket_code)

    assert {:ok, _} =
             MobileIntegrationScenario.set_ticket_payment_status(
               event.id,
               attendee.ticket_code,
               "refunded"
             )

    assert {:ok, state} =
             MobileIntegrationScenario.dump_ticket_state(event.id, attendee.ticket_code)

    assert state.event_id == event.id
    assert state.ticket_code == attendee.ticket_code
    assert state.attendee_id == attendee.id
    assert state.scan_eligibility == "not_scannable"
    assert state.payment_status == "refunded"
    assert is_integer(state.event_sync_version)
    assert state.event_sync_version >= 2
    assert is_list(state.invalidations)
    assert length(state.invalidations) >= 1
    assert Enum.all?(state.invalidations, &Map.has_key?(&1, :reason_code))
  end

  defp insert_event! do
    api_key = "scenario-api-key-#{System.unique_integer([:positive])}"
    {:ok, encrypted_api_key} = Crypto.encrypt(api_key)
    {:ok, encrypted_secret} = Crypto.encrypt("scenario-secret")

    %Event{}
    |> Event.changeset(%{
      mobile_access_secret_encrypted: encrypted_secret,
      name: "Integration Scenario Event #{System.unique_integer([:positive])}",
      scanner_login_code: random_scanner_code(),
      site_url: "https://example.com",
      status: "active",
      tickera_api_key_encrypted: encrypted_api_key,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      tickera_site_url: "https://example.com",
      total_tickets: 1
    })
    |> Repo.insert!()
  end

  defp insert_attendee!(event_id, ticket_code) do
    %Attendee{
      allowed_checkins: 1,
      checkins_remaining: 1,
      email: "scenario@example.com",
      event_id: event_id,
      first_name: "Scenario",
      is_currently_inside: false,
      last_name: "Tester",
      payment_status: "completed",
      ticket_code: ticket_code,
      ticket_type: "General"
    }
    |> Repo.insert!()
  end

  defp random_scanner_code do
    Ecto.UUID.generate()
    |> String.replace("-", "")
    |> String.upcase()
    |> String.slice(0, 6)
  end
end
