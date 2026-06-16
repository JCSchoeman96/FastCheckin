defmodule FastCheck.Observability.TelemetryNamesTest do
  use ExUnit.Case, async: true

  alias FastCheck.Observability.TelemetryNames

  @expected_count 23

  test "all/0 returns exactly 23 approved list-style events" do
    events = TelemetryNames.all()

    assert length(events) == @expected_count
    assert Enum.all?(events, &valid_event_name?/1)
    assert length(Enum.uniq(events)) == @expected_count
  end

  test "event groups match the VS-21A catalog" do
    assert length(TelemetryNames.checkout_events()) == 3
    assert length(TelemetryNames.inventory_events()) == 4
    assert length(TelemetryNames.payment_events()) == 5
    assert length(TelemetryNames.ticket_events()) == 3
    assert length(TelemetryNames.scanner_visibility_events()) == 1
    assert length(TelemetryNames.delivery_events()) == 3
    assert length(TelemetryNames.whatsapp_events()) == 2
    assert length(TelemetryNames.manual_review_events()) == 2
  end

  test "never builds event names from user input" do
    user_input = "checkout"

    refute Enum.any?(TelemetryNames.all(), fn event ->
             Enum.any?(event, &(to_string(&1) == user_input and &1 != :checkout))
           end)
  end

  defp valid_event_name?(event) when is_list(event) do
    match?([:fastcheck, :sales, _, _], event) and Enum.all?(event, &is_atom/1)
  end
end
