defmodule FastCheck.Operations.ObanSnapshot.RedisMirrorTest do
  use ExUnit.Case, async: false

  alias FastCheck.Operations.ObanSnapshot.RedisMirror

  test "lease acquisition always disables local Redis fallback" do
    parent = self()

    command = fn args, opts ->
      send(parent, {:redis, args, opts})
      {:ok, "OK"}
    end

    assert {:ok, true} = RedisMirror.acquire_lease("node-a", command_fun: command)
    assert_receive {:redis, ["SET", key, "node-a", "NX", "PX", "14000"], [fallback: false]}
    assert key =~ "fastcheck:ops:oban:collect_lease"
  end

  test "a Redis outage is not reported as a successful lease" do
    command = fn _args, opts ->
      send(self(), {:opts, opts})
      {:error, :redis_unavailable}
    end

    assert {:error, :redis_unavailable} =
             RedisMirror.acquire_lease("node-a", command_fun: command)

    assert_receive {:opts, [fallback: false]}
  end

  test "snapshot writes and reads are namespaced JSON operations without fallback" do
    parent = self()

    snapshot = %{
      version: 1,
      collected_at: ~U[2026-10-01 10:00:00Z],
      collector_node: "node-a",
      distribution_mode: "shared",
      queues: []
    }

    command = fn args, opts ->
      send(parent, {:redis, args, opts})

      case args do
        ["SET", _key, _payload, "EX", "60"] -> {:ok, "OK"}
        ["GET", _key] -> {:ok, Jason.encode!(snapshot)}
      end
    end

    assert :ok = RedisMirror.write_snapshot(snapshot, command_fun: command)
    assert {:ok, decoded} = RedisMirror.read_snapshot(command_fun: command)
    assert decoded["version"] == 1

    assert_receive {:redis, ["SET", set_key, _payload, "EX", "60"], [fallback: false]}
    assert set_key =~ "fastcheck:ops:oban:snapshot"
    assert_receive {:redis, ["GET", get_key], [fallback: false]}
    assert get_key == set_key
  end
end
