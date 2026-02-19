defmodule FastCheck.Events.ConfigTest do
  use FastCheck.DataCase, async: true

  alias FastCheck.Events.Config

  describe "module exports" do
    test "exports fetch_and_store_ticket_configs/1" do
      Code.ensure_loaded!(Config)
      assert function_exported?(Config, :fetch_and_store_ticket_configs, 1)
    end
  end
end
