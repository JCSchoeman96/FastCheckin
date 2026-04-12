defmodule FastCheck.Scans.HotState.RedisStoreTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Scans.HotState.{Keyspace, RedisStore}
  alias FastCheck.Scans.Ingest.ScanCommand

  setup do
    assert is_pid(Process.whereis(FastCheck.Redix))

    event = create_event()

    attendee =
      create_attendee(event, %{
        ticket_code: "TEST001",
        allowed_checkins: 1,
        checkins_remaining: 1,
        payment_status: "completed"
      })

    other_attendee =
      create_attendee(event, %{
        ticket_code: "TEST002",
        allowed_checkins: 1,
        checkins_remaining: 1,
        payment_status: "completed"
      })

    namespace = unique_namespace("redis-store")
    cleanup_namespace(namespace, event.id)

    on_exit(fn -> cleanup_namespace(namespace, event.id) end)

    %{event: event, attendee: attendee, other_attendee: other_attendee, namespace: namespace}
  end

  test "cold load creates and publishes an active snapshot version", %{
    event: event,
    namespace: namespace
  } do
    assert {:ok, version} = RedisStore.ensure_event_loaded(event.id, namespace)
    assert is_binary(version)

    assert {:ok, ^version} =
             Redix.command(FastCheck.Redix, ["GET", Keyspace.active_version(namespace, event.id)])
  end

  test "process_scan replays pending and final acknowledged results", %{
    event: event,
    namespace: namespace
  } do
    command = scan_command(event.id, "idem-1", "TEST001")

    assert {:ok, first} = RedisStore.process_scan(command, namespace)
    assert first.status == "success"
    assert first.delivery_state == :new_staged

    assert {:ok, pending_replay} = RedisStore.process_scan(command, namespace)
    assert pending_replay.status == "success"
    assert pending_replay.delivery_state == :pending_durability

    assert :ok = RedisStore.promote_results([first], namespace)

    assert {:ok, final_replay} = RedisStore.process_scan(command, namespace)
    assert final_replay.delivery_state == :final_acknowledged
    assert final_replay.status == "success"
  end

  test "classifies same-ticket different-idempotency bursts as duplicate on the warm path", %{
    event: event,
    namespace: namespace
  } do
    assert {:ok, _version} = RedisStore.ensure_event_loaded(event.id, namespace)

    assert {:ok, first} =
             RedisStore.process_scan(scan_command(event.id, "burst-1", "TEST001"), namespace)

    assert first.status == "success"

    assert {:ok, duplicate} =
             RedisStore.process_scan(scan_command(event.id, "burst-2", "TEST001"), namespace)

    assert duplicate.status == "error"
    assert duplicate.reason_code == "DUPLICATE"
    assert duplicate.delivery_state == :new_staged
    assert duplicate.message =~ "Already checked in"
  end

  test "returns build_timeout when a cold-load build lock is held without an active version", %{
    event: event,
    namespace: namespace
  } do
    lock_key = Keyspace.build_lock(namespace, event.id)

    assert {:ok, "OK"} =
             Redix.command(FastCheck.Redix, ["SET", lock_key, "1", "NX", "EX", "30"])

    assert {:error, :build_timeout} = RedisStore.ensure_event_loaded(event.id, namespace)
  end

  test "process_scan rejects not_scannable tickets before Redis Lua decision", %{
    event: event,
    namespace: namespace
  } do
    _revoked =
      create_attendee(event, %{
        ticket_code: "REVOKED-1",
        allowed_checkins: 1,
        checkins_remaining: 1,
        payment_status: "completed",
        scan_eligibility: "not_scannable"
      })

    assert {:ok, result} =
             RedisStore.process_scan(
               scan_command(event.id, "idem-revoked", "REVOKED-1"),
               namespace
             )

    assert result.status == "error"
    assert result.reason_code == "TICKET_NOT_SCANNABLE"
    assert result.message =~ "no longer valid for scanning"
    assert result.delivery_state == :new_staged
  end

  test "rejects out direction as not implemented instead of returning success", %{
    event: event,
    namespace: namespace
  } do
    assert {:ok, result} =
             RedisStore.process_scan(
               scan_command(event.id, "idem-out-1", "TEST001", "out"),
               namespace
             )

    assert result.status == "error"
    assert result.reason_code == "NOT_IMPLEMENTED"
    assert result.delivery_state == :new_staged
    assert result.message =~ "Check-out functionality not yet available"
  end

  defp scan_command(event_id, idempotency_key, ticket_code, direction \\ "in") do
    %ScanCommand{
      event_id: event_id,
      idempotency_key: idempotency_key,
      ticket_code: ticket_code,
      direction: direction,
      entrance_name: "Main Gate",
      operator_name: "Scanner 1",
      scanned_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp cleanup_namespace(namespace, event_id) do
    pattern = "fastcheck:mobile_scans:#{namespace}:event:#{event_id}:*"

    case scan_redis_keys(pattern) do
      [] ->
        :ok

      keys ->
        assert {:ok, _deleted} = Redix.command(FastCheck.Redix, ["DEL" | keys])
    end
  end

  defp scan_redis_keys(pattern), do: do_scan_redis_keys("0", pattern, [])

  defp do_scan_redis_keys(cursor, pattern, keys) do
    assert {:ok, [next_cursor, batch]} =
             Redix.command(FastCheck.Redix, ["SCAN", cursor, "MATCH", pattern, "COUNT", "500"])

    updated = batch ++ keys

    if next_cursor == "0" do
      updated
    else
      do_scan_redis_keys(next_cursor, pattern, updated)
    end
  end

  defp unique_namespace(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
