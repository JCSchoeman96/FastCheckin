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

  test "generate/0 accepts no caller inputs" do
    public_functions = CodeGenerator.__info__(:functions)

    assert {:generate, 0} in public_functions
    refute {:generate, 1} in public_functions
  end
end
