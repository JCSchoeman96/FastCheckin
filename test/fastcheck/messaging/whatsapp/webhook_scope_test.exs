defmodule FastCheck.Messaging.WhatsApp.WebhookScopeTest do
  use ExUnit.Case, async: true

  alias FastCheck.Messaging.WhatsApp.Config
  alias FastCheck.Messaging.WhatsApp.WebhookScope

  @config %Config{business_account_id: "business-123", phone_number_id: "phone-123"}

  test "retains a matching WABA and phone message change" do
    payload = payload("business-123", [change("phone-123", "messages")])

    assert {:ok, scoped} = WebhookScope.filter(payload, @config)
    assert scoped == payload
  end

  test "ignores a wrong WABA" do
    payload = payload("business-other", [change("phone-123", "messages")])

    assert {:ignore, :out_of_scope} = WebhookScope.filter(payload, @config)
  end

  test "ignores a correct WABA with a wrong phone" do
    payload = payload("business-123", [change("phone-other", "messages")])

    assert {:ignore, :out_of_scope} = WebhookScope.filter(payload, @config)
  end

  test "ignores when both WABA and phone are wrong" do
    payload = payload("business-other", [change("phone-other", "messages")])

    assert {:ignore, :out_of_scope} = WebhookScope.filter(payload, @config)
  end

  test "fails closed when the entry WABA is absent" do
    payload = %{"object" => "whatsapp_business_account", "entry" => [%{"changes" => []}]}

    assert {:ignore, :malformed_scope} = WebhookScope.filter(payload, @config)
  end

  test "fails closed when the phone metadata is absent" do
    payload = payload("business-123", [change(nil, "messages")])

    assert {:ignore, :malformed_scope} = WebhookScope.filter(payload, @config)
  end

  test "retains only matching entries in a mixed-WABA payload" do
    matching = payload("business-123", [change("phone-123", "messages")])
    other = payload("business-other", [change("phone-123", "messages")])

    mixed = %{
      "object" => "whatsapp_business_account",
      "entry" => matching["entry"] ++ other["entry"]
    }

    assert {:ok, scoped} = WebhookScope.filter(mixed, @config)
    assert scoped["entry"] == matching["entry"]
  end

  test "retains only matching phone changes under the correct WABA" do
    matching_change = change("phone-123", "messages")
    other_change = change("phone-other", "statuses")
    payload = payload("business-123", [matching_change, other_change])

    assert {:ok, scoped} = WebhookScope.filter(payload, @config)
    assert scoped["entry"] == [%{"id" => "business-123", "changes" => [matching_change]}]
  end

  test "retains matching status changes for later reconciliation" do
    payload = payload("business-123", [change("phone-123", "statuses")])

    assert {:ok, scoped} = WebhookScope.filter(payload, @config)
    assert scoped == payload
  end

  test "unsupported provider changes do not bypass scope" do
    unsupported = %{
      "field" => "account",
      "value" => %{
        "metadata" => %{"phone_number_id" => "phone-123"},
        "account_update" => [%{"status" => "updated"}]
      }
    }

    payload = payload("business-123", [unsupported])

    assert {:ignore, :out_of_scope} = WebhookScope.filter(payload, @config)
  end

  defp payload(entry_id, changes) do
    %{
      "object" => "whatsapp_business_account",
      "entry" => [%{"id" => entry_id, "changes" => changes}]
    }
  end

  defp change(phone_number_id, activity) do
    value = %{
      "metadata" => if(phone_number_id, do: %{"phone_number_id" => phone_number_id}, else: %{})
    }

    Map.put(value, activity, [%{"id" => "wamid.scope-test"}])
    |> then(&%{"field" => "messages", "value" => &1})
  end
end
