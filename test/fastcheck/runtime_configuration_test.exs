defmodule FastCheck.RuntimeConfigurationTest do
  use ExUnit.Case, async: true

  alias FastCheck.RuntimeConfiguration

  @strong_password "1234567890abcdef"

  describe "dashboard_credentials/3 in production" do
    test "rejects a missing username" do
      assert {:error, :missing_username} = dashboard_credentials(:prod, nil, @strong_password)
    end

    test "rejects a blank username" do
      assert {:error, :blank_username} = dashboard_credentials(:prod, " \t\n", @strong_password)
    end

    test "rejects a missing password" do
      assert {:error, :missing_password} = dashboard_credentials(:prod, "admin", nil)
    end

    test "rejects a blank password" do
      assert {:error, :blank_password} = dashboard_credentials(:prod, "admin", " \t\n")
    end

    test "rejects the known development fallback password" do
      assert {:error, :development_fallback_password} =
               dashboard_credentials(:prod, "admin", "fastcheck")
    end

    test "rejects passwords shorter than 16 bytes" do
      assert {:error, :password_too_short} = dashboard_credentials(:prod, "admin", "short")
    end

    test "accepts a password exactly 16 bytes long" do
      assert {:ok, %{username: "admin", password: @strong_password}} =
               dashboard_credentials(:prod, "admin", @strong_password)
    end

    test "accepts passwords longer than 16 bytes" do
      password = String.duplicate("p", 17)

      assert {:ok, %{username: "admin", password: ^password}} =
               dashboard_credentials(:prod, "admin", password)
    end

    test "trims values before validating and returning them" do
      assert {:ok, %{username: "admin", password: @strong_password}} =
               dashboard_credentials(:prod, " admin ", "  #{@strong_password} \t")
    end

    test "allows an explicitly configured admin username" do
      assert {:ok, %{username: "admin", password: @strong_password}} =
               dashboard_credentials(:prod, "admin", @strong_password)
    end
  end

  describe "dashboard_credentials/3 outside production" do
    test "uses development defaults when values are missing" do
      assert {:ok, %{username: "admin", password: "fastcheck"}} =
               dashboard_credentials(:dev, nil, nil)
    end

    test "uses development defaults when values are blank" do
      assert {:ok, %{username: "admin", password: "fastcheck"}} =
               dashboard_credentials(:test, " \t", " \n")
    end

    test "trims and retains explicit values" do
      assert {:ok, %{username: "operator", password: "local-password"}} =
               dashboard_credentials(:dev, " operator ", " local-password ")
    end
  end

  defp dashboard_credentials(environment, username, password) do
    RuntimeConfiguration.dashboard_credentials(environment, username, password)
  end
end
