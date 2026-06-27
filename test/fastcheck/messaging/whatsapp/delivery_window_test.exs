defmodule FastCheck.Messaging.WhatsApp.DeliveryWindowTest do
  use ExUnit.Case, async: true

  alias FastCheck.Messaging.WhatsApp.DeliveryWindow

  @now ~U[2026-06-27 10:00:00Z]

  test "allows session messages when the last customer message is inside 24 hours" do
    assert DeliveryWindow.inside?(~U[2026-06-26 10:00:01Z], @now)
  end

  test "allows session messages exactly at the 24 hour boundary" do
    assert DeliveryWindow.inside?(~U[2026-06-26 10:00:00Z], @now)
  end

  test "closes the session message window after 24 hours" do
    refute DeliveryWindow.inside?(~U[2026-06-26 09:59:59Z], @now)
  end

  test "treats missing message timestamps as outside the session window" do
    refute DeliveryWindow.inside?(nil, @now)
  end

  test "treats future timestamps as inside to tolerate small clock skew" do
    assert DeliveryWindow.inside?(~U[2026-06-27 10:05:00Z], @now)
  end
end
