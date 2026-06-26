defmodule FastCheck.Messaging.WhatsApp.InputNormalizerTest do
  use ExUnit.Case, async: true

  alias FastCheck.Messaging.WhatsApp.InputNormalizer

  describe "normalize/1" do
    test "normalizes number-only commands" do
      assert {:ok, {:number, 1}} = InputNormalizer.normalize("1")
      assert {:ok, {:number, 9}} = InputNormalizer.normalize(" 9 ")
      assert {:ok, :back} = InputNormalizer.normalize("0")
      assert {:ok, :restart} = InputNormalizer.normalize("#")
    end

    test "normalizes support commands without case sensitivity" do
      assert {:ok, :help} = InputNormalizer.normalize("HELP")
      assert {:ok, :help} = InputNormalizer.normalize(" help ")
      assert {:ok, :stop} = InputNormalizer.normalize("Stop")
    end

    test "classifies bounded free text without logging or transforming it" do
      assert {:ok, {:text, "Jan Burger"}} = InputNormalizer.normalize(" Jan Burger ")
      assert {:ok, {:text, "jan@example.com"}} = InputNormalizer.normalize("jan@example.com")
    end

    test "rejects blank, non-text, multi-digit, and oversized input" do
      assert {:error, :blank} = InputNormalizer.normalize("  ")
      assert {:error, :invalid} = InputNormalizer.normalize(nil)
      assert {:error, :invalid} = InputNormalizer.normalize("10")
      assert {:error, :too_long} = InputNormalizer.normalize(String.duplicate("a", 257))
    end
  end
end
