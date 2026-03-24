defmodule FastCheck.Scans.IngestionModeTest do
  use ExUnit.Case, async: true

  alias FastCheck.Scans.IngestionMode

  test "resolves explicit supported modes" do
    assert IngestionMode.resolve("redis_authoritative") == :redis_authoritative
    assert IngestionMode.resolve("shadow") == :shadow
    assert IngestionMode.resolve("legacy") == :legacy
    assert IngestionMode.resolve(:redis_authoritative) == :redis_authoritative
    assert IngestionMode.resolve(:shadow) == :shadow
    assert IngestionMode.resolve(:legacy) == :legacy
  end

  test "falls back to legacy for blank, unknown, or malformed values" do
    assert IngestionMode.resolve(nil) == :legacy
    assert IngestionMode.resolve("") == :legacy
    assert IngestionMode.resolve("   ") == :legacy
    assert IngestionMode.resolve("unknown") == :legacy
    assert IngestionMode.resolve("REDIS-AUTHORITATIVE") == :legacy
    assert IngestionMode.resolve(:unexpected) == :legacy
  end
end
