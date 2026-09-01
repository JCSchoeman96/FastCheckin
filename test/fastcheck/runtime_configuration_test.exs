defmodule FastCheck.RuntimeConfigurationTest do
  use ExUnit.Case, async: true

  alias FastCheck.RuntimeConfiguration

  describe "dashboard_credentials/3" do
    test "requires explicit production credentials" do
      assert {:error, :missing_username} =
               RuntimeConfiguration.dashboard_credentials(:prod, nil, "long-enough-password")

      assert {:error, :missing_password} =
               RuntimeConfiguration.dashboard_credentials(:prod, "admin", nil)

      assert {:error, :development_fallback_password} =
               RuntimeConfiguration.dashboard_credentials(:prod, "admin", "FASTCHECK")

      assert {:error, :password_too_short} =
               RuntimeConfiguration.dashboard_credentials(:prod, "admin", "short-password")

      assert {:ok, %{username: "operator", password: "sixteen-character"}} =
               RuntimeConfiguration.dashboard_credentials(
                 :prod,
                 " operator ",
                 " sixteen-character "
               )
    end

    test "keeps development defaults usable" do
      assert {:ok, %{username: "admin", password: "fastcheck"}} =
               RuntimeConfiguration.dashboard_credentials(:dev, nil, nil)

      assert {:ok, %{username: "admin", password: "fastcheck"}} =
               RuntimeConfiguration.dashboard_credentials(:test, " ", " ")
    end
  end

  describe "strict_boolean/1" do
    test "accepts only documented boolean spellings" do
      for value <- ~w(1 true yes on TRUE Yes ON) do
        assert {:ok, true} = RuntimeConfiguration.strict_boolean(value)
      end

      for value <- ~w(0 false no off FALSE No OFF) do
        assert {:ok, false} = RuntimeConfiguration.strict_boolean(value)
      end

      assert :error = RuntimeConfiguration.strict_boolean("maybe")
      assert :error = RuntimeConfiguration.strict_boolean(1)
    end
  end

  describe "whatsapp_sandbox_mode/3" do
    test "requires an explicit valid production value when enabled" do
      assert {:error, :missing} = RuntimeConfiguration.whatsapp_sandbox_mode(:prod, true, nil)
      assert {:error, :missing} = RuntimeConfiguration.whatsapp_sandbox_mode(:prod, true, " ")
      assert {:error, :invalid} = RuntimeConfiguration.whatsapp_sandbox_mode(:prod, true, "maybe")
      assert {:ok, false} = RuntimeConfiguration.whatsapp_sandbox_mode(:prod, true, " OFF ")
    end

    test "defaults only non-production environments" do
      assert {:ok, true} = RuntimeConfiguration.whatsapp_sandbox_mode(:dev, true, nil)
      assert {:ok, false} = RuntimeConfiguration.whatsapp_sandbox_mode(:dev, true, "invalid")
    end
  end
end
