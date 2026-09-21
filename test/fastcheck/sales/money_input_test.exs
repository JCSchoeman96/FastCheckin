defmodule FastCheck.Sales.MoneyInputTest do
  use ExUnit.Case, async: true

  alias FastCheck.Sales.MoneyInput

  test "parses whole and decimal ZAR amounts exactly" do
    assert {:ok, 10_000} = MoneyInput.parse_zar_to_cents("100")
    assert {:ok, 10_000} = MoneyInput.parse_zar_to_cents("100.00")
    assert {:ok, 9995} = MoneyInput.parse_zar_to_cents("99.95")
  end

  test "rejects malformed, negative, and over-precision money" do
    assert {:error, :invalid_money} = MoneyInput.parse_zar_to_cents("-1")
    assert {:error, :invalid_money} = MoneyInput.parse_zar_to_cents("abc")
    assert {:error, :invalid_money} = MoneyInput.parse_zar_to_cents("1.234")
    assert {:error, :invalid_money} = MoneyInput.parse_zar_to_cents("")
  end

  test "returns integer cents without fractional results" do
    assert {:ok, cents} = MoneyInput.parse_zar_to_cents("99.95")
    assert is_integer(cents)
    assert cents == 9995
  end
end
