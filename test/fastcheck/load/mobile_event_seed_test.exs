defmodule FastCheck.Load.MobileEventSeedTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Load.MobileEventSeed
  alias FastCheck.Repo

  test "seeds a deterministic event, attendees, and manifest" do
    manifest_path =
      Path.join(System.tmp_dir!(), "mobile-load-event-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(manifest_path) end)

    result =
      MobileEventSeed.seed!(%{
        attendees: 40,
        credential: "scanner-secret",
        event_name: "Perf Seed Event",
        output: manifest_path,
        scanner_code: "ABC123",
        ticket_prefix: "PERF"
      })

    assert result.event.name == "Perf Seed Event"
    assert result.event.scanner_login_code == "ABC123"
    assert result.manifest_path == Path.expand(manifest_path)

    attendees =
      Repo.all(
        from attendee in Attendee,
          where: attendee.event_id == ^result.event.id,
          order_by: [asc: attendee.ticket_code]
      )

    assert length(attendees) == 40
    assert hd(attendees).ticket_code == "PERF-000001"
    assert List.last(attendees).ticket_code == "PERF-000040"

    manifest = result.manifest
    assert manifest.event_id == result.event.id
    assert manifest.ticket_prefix == "PERF"
    assert manifest.ticket_count == 40
    assert manifest.invalid_prefix == "INVALID-PERF"
    assert manifest.control_ranges.replay_prime_count == 5
    assert manifest.control_ranges.business_prime_count == 4

    slice_names = [:baseline_valid, :business_duplicate, :offline_burst, :soak]

    slice_counts =
      Enum.map(slice_names, fn slice_name ->
        manifest.slices
        |> Map.fetch!(slice_name)
        |> Map.fetch!(:count)
      end)

    assert Enum.sum(slice_counts) == 40

    ranges =
      Enum.map(slice_names, fn slice_name ->
        slice = Map.fetch!(manifest.slices, slice_name)
        {slice.start_index, slice.end_index}
      end)

    assert ranges == [{1, 16}, {17, 20}, {21, 29}, {30, 40}]
    assert File.exists?(manifest_path)
    assert Jason.decode!(File.read!(manifest_path))["event_id"] == result.event.id
  end

  test "generates unique scanner codes when none are provided" do
    first_manifest_path =
      Path.join(System.tmp_dir!(), "mobile-load-event-#{System.unique_integer([:positive])}.json")

    second_manifest_path =
      Path.join(System.tmp_dir!(), "mobile-load-event-#{System.unique_integer([:positive])}.json")

    on_exit(fn ->
      File.rm(first_manifest_path)
      File.rm(second_manifest_path)
    end)

    first =
      MobileEventSeed.seed!(%{
        attendees: 20,
        credential: "scanner-secret",
        output: first_manifest_path,
        ticket_prefix: "AUTOA"
      })

    second =
      MobileEventSeed.seed!(%{
        attendees: 20,
        credential: "scanner-secret",
        output: second_manifest_path,
        ticket_prefix: "AUTOB"
      })

    refute first.event.scanner_login_code == second.event.scanner_login_code
    assert first.event.scanner_login_code =~ ~r/^[0-9A-F]{6}$/
    assert second.event.scanner_login_code =~ ~r/^[0-9A-F]{6}$/
  end
end
