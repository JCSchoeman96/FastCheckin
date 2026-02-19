defmodule FastCheck.Events.StatsTest do
  use FastCheck.DataCase, async: true

  alias FastCheck.Events.Stats

  describe "module exports" do
    test "exports get_event_stats/1" do
      assert_exported(Stats, :get_event_stats, 1)
    end

    test "exports get_event_with_stats/1" do
      assert_exported(Stats, :get_event_with_stats, 1)
    end

    test "exports update_occupancy/2" do
      assert_exported(Stats, :update_occupancy, 2)
    end

    test "exports get_event_advanced_stats/1" do
      assert_exported(Stats, :get_event_advanced_stats, 1)
    end

    test "exports update_event_occupancy_live/1" do
      assert_exported(Stats, :update_event_occupancy_live, 1)
    end

    test "exports broadcast_event_stats/2" do
      assert_exported(Stats, :broadcast_event_stats, 2)
    end

    test "exports broadcast_occupancy_update/2" do
      assert_exported(Stats, :broadcast_occupancy_update, 2)
    end

    test "exports broadcast_occupancy_breakdown/1" do
      assert_exported(Stats, :broadcast_occupancy_breakdown, 1)
    end

    test "exports invalidate_event_stats_cache/1" do
      assert_exported(Stats, :invalidate_event_stats_cache, 1)
    end

    test "exports invalidate_occupancy_cache/1" do
      assert_exported(Stats, :invalidate_occupancy_cache, 1)
    end
  end

  defp assert_exported(module, function, arity) do
    Code.ensure_loaded!(module)
    assert function_exported?(module, function, arity)
  end
end
