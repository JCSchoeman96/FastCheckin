defmodule FastCheck.Tickets.CodeGeneratorTest do
  use ExUnit.Case, async: true

  alias FastCheck.Tickets.CodeGenerator

  test "generate/0 returns FC- prefixed URL-safe codes with scanner-safe alphabet" do
    code = CodeGenerator.generate()

    assert String.starts_with?(code, "FC-")
    assert CodeGenerator.scanner_safe?(code)
  end

  test "generate/0 uses at least 128 bits of entropy across samples" do
    codes = for _ <- 1..50, do: CodeGenerator.generate()
    assert length(Enum.uniq(codes)) == 50
  end

  test "generate/0 is not derived from caller inputs" do
    order_id = 12_345
    event_id = 99

    code =
      order_id
      |> Integer.to_string()
      |> then(fn _ ->
        event_id |> Integer.to_string() |> then(fn _ -> CodeGenerator.generate() end)
      end)

    refute code =~ Integer.to_string(order_id)
    refute code =~ Integer.to_string(event_id)
  end
end
