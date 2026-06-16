defmodule FastCheck.Sales.Inventory.RedisScriptsTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Sales.Inventory.RedisScripts

  @offer_id 44_003

  test "script module exposes reserve, consume and release execution entrypoints" do
    assert Code.ensure_loaded?(RedisScripts)
    assert function_exported?(RedisScripts, :reserve, 1)
    assert function_exported?(RedisScripts, :consume, 1)
    assert function_exported?(RedisScripts, :release, 1)
  end

  test "script module normalizes redis unavailable errors to ledger_unavailable" do
    assert {:error, :ledger_unavailable, _meta} =
             RedisScripts.execute("EVAL", ["return 1", "0"], redix_name: :missing_redix_process)
  end

  test "script module maps unknown status codes to unexpected_redis_response" do
    script = "return {'totally_unknown'}"

    assert {:error, :unexpected_redis_response, _meta} =
             RedisScripts.execute("EVAL", [script, "0"],
               redix_name: FastCheck.Redix,
               offer_id: @offer_id
             )
  end

  test "script module maps canonical error families from lua status codes" do
    assert {:error, :invalid_idempotency_key, %{reason: :duplicate_conflict}} =
             decode_status("DUPLICATE_CONFLICT")

    assert {:error, :invalid_quantity, %{reason: :quantity_mismatch}} =
             decode_status("QUANTITY_MISMATCH")

    assert {:error, :hold_expired, _} = decode_status("ALREADY_EXPIRED")
    assert {:error, :already_released, _} = decode_status("ALREADY_RELEASED")
    assert {:error, :lock_timeout, _} = decode_status("LOCK_TIMEOUT")
  end

  defp decode_status(status) do
    script = "return {'#{status}'}"

    RedisScripts.execute("EVAL", [script, "0"], redix_name: FastCheck.Redix, offer_id: @offer_id)
  end
end
