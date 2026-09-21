defmodule FastCheck.Sales.Inventory.ReservationLedgerInitializeIfAbsentTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Sales.Inventory.ReservationLedger

  @offer_id 44_050
  @quantity 10

  setup do
    flush_inventory_keys(@offer_id)
    on_exit(fn -> flush_inventory_keys(@offer_id) end)
    :ok
  end

  test "initialize_offer_if_absent creates a fresh ledger when the key is absent" do
    assert :ok = ReservationLedger.initialize_offer_if_absent(@offer_id, @quantity)

    assert {:ok, snapshot} = ReservationLedger.get_availability(@offer_id)
    assert snapshot.configured_quantity == @quantity
    assert snapshot.available_quantity == @quantity
    assert snapshot.reserved_quantity == 0
    assert snapshot.consumed_quantity == 0
    assert snapshot.revision == 1
    assert snapshot.ledger_state == :healthy
  end

  test "initialize_offer_if_absent returns already_initialized when the key exists" do
    assert :ok = ReservationLedger.initialize_offer_if_absent(@offer_id, @quantity)

    assert {:error, :already_initialized, %{offer_id: @offer_id}} =
             ReservationLedger.initialize_offer_if_absent(@offer_id, @quantity)
  end

  test "initialize_offer_if_absent does not reset a ledger with active reservations" do
    run_id = System.unique_integer([:positive])

    assert :ok = ReservationLedger.initialize_offer_if_absent(@offer_id, @quantity)

    assert {:ok, held} =
             ReservationLedger.reserve(
               @offer_id,
               "ORD-INIT-#{run_id}",
               2,
               120,
               "idem-init-#{run_id}"
             )

    assert held.status == :held

    assert {:ok, before} = ReservationLedger.get_availability(@offer_id)
    assert before.available_quantity == 8
    assert before.reserved_quantity == 2
    assert before.revision > 1

    assert {:error, :already_initialized, _} =
             ReservationLedger.initialize_offer_if_absent(@offer_id, @quantity)

    assert {:ok, after_retry} = ReservationLedger.get_availability(@offer_id)
    assert after_retry.available_quantity == before.available_quantity
    assert after_retry.reserved_quantity == before.reserved_quantity
    assert after_retry.consumed_quantity == before.consumed_quantity
    assert after_retry.revision == before.revision
    assert after_retry.ledger_state == before.ledger_state

    assert {:ok, 1} =
             Redix.command(FastCheck.Redix, [
               "EXISTS",
               ReservationLedger.hold_key("ORD-INIT-#{run_id}")
             ])
  end

  test "parallel initialize_offer_if_absent attempts initialize exactly once" do
    results =
      1..2
      |> Task.async_stream(
        fn _ ->
          ReservationLedger.initialize_offer_if_absent(@offer_id, @quantity)
        end,
        max_concurrency: 2,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1

    assert Enum.count(results, fn
             {:error, :already_initialized, _} -> true
             _ -> false
           end) == 1

    assert {:ok, snapshot} = ReservationLedger.get_availability(@offer_id)
    assert snapshot.configured_quantity == @quantity
    assert snapshot.available_quantity == @quantity
    assert snapshot.reserved_quantity == 0
    assert snapshot.revision == 1
  end

  defp flush_inventory_keys(offer_id) do
    keys = [
      "sales:offer:#{offer_id}:inventory",
      "sales:offer:#{offer_id}:holds",
      "sales:inventory:events:#{offer_id}"
    ]

    _ = Redix.command(FastCheck.Redix, ["DEL" | keys])
    scan_delete_all("sales:hold:*")
    scan_delete_all("sales:order:*:lock")
    scan_delete_all("sales:inventory:dedupe:*")
    :ok
  end

  defp scan_delete_all(pattern) do
    do_scan_delete_all("0", pattern)
  end

  defp do_scan_delete_all(cursor, pattern) do
    case Redix.command(FastCheck.Redix, ["SCAN", cursor, "MATCH", pattern, "COUNT", "500"]) do
      {:ok, [next_cursor, keys]} ->
        if keys != [], do: _ = Redix.command(FastCheck.Redix, ["DEL" | keys])

        if next_cursor == "0" do
          :ok
        else
          do_scan_delete_all(next_cursor, pattern)
        end

      _ ->
        :ok
    end
  end
end
