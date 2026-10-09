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

  describe "dashboard_event_creation_enabled/1" do
    test "treats missing, empty, and whitespace-only values as disabled" do
      for raw_value <- [nil, "", " \t\n "] do
        assert {:ok, false} = RuntimeConfiguration.dashboard_event_creation_enabled(raw_value)
      end
    end

    test "accepts canonical true values" do
      for raw_value <- ["1", "true", "yes", "on"] do
        assert {:ok, true} = RuntimeConfiguration.dashboard_event_creation_enabled(raw_value)
      end
    end

    test "accepts canonical false values" do
      for raw_value <- ["0", "false", "no", "off"] do
        assert {:ok, false} = RuntimeConfiguration.dashboard_event_creation_enabled(raw_value)
      end
    end

    test "trims and lowercases before parsing" do
      assert {:ok, true} = RuntimeConfiguration.dashboard_event_creation_enabled("  TRUE  ")
      assert {:ok, false} = RuntimeConfiguration.dashboard_event_creation_enabled("\n OFF\t")
    end

    test "rejects invalid nonblank values" do
      for raw_value <- ["enabled", "2", "maybe"] do
        assert {:error, :invalid_dashboard_event_creation_enabled} =
                 RuntimeConfiguration.dashboard_event_creation_enabled(raw_value)
      end
    end

    test "rejects nonbinary input" do
      assert {:error, :invalid_dashboard_event_creation_enabled} =
               RuntimeConfiguration.dashboard_event_creation_enabled(true)

      assert {:error, :invalid_dashboard_event_creation_enabled} =
               RuntimeConfiguration.dashboard_event_creation_enabled(1)
    end
  end

  describe "dashboard_event_ids/1" do
    test "treats a missing or blank setting as an empty grant" do
      assert {:ok, []} = RuntimeConfiguration.dashboard_event_ids(nil)
      assert {:ok, []} = RuntimeConfiguration.dashboard_event_ids("")
      assert {:ok, []} = RuntimeConfiguration.dashboard_event_ids(" \t\n ")
    end

    test "trims values and returns sorted, deduplicated positive event ids" do
      assert {:ok, [12, 14, 27]} =
               RuntimeConfiguration.dashboard_event_ids(" 14, 12,14,27 ")
    end

    test "rejects zero, negative ids, wildcards, and non-integer values" do
      for raw_value <- ["0", "-1", "*", "all", "12x", "12.5"] do
        assert {:error, :invalid_dashboard_event_ids} =
                 RuntimeConfiguration.dashboard_event_ids(raw_value)
      end
    end

    test "rejects empty entries and never partially accepts malformed input" do
      for raw_value <- ["12,,14", "12,", ",12", "12,garbage,14", " , "] do
        assert {:error, :invalid_dashboard_event_ids} =
                 RuntimeConfiguration.dashboard_event_ids(raw_value)
      end
    end
  end

  defp dashboard_credentials(environment, username, password) do
    RuntimeConfiguration.dashboard_credentials(environment, username, password)
  end
end
