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
             RedisScripts.execute("EVAL", [script, "0"], redix_name: FastCheck.Redix, offer_id: @offer_id)
  end
end
