defmodule FastCheck.Messaging.WhatsApp.WebhookScopeTest do
  use ExUnit.Case, async: true

  alias FastCheck.Messaging.WhatsApp.Config
  alias FastCheck.Messaging.WhatsApp.WebhookScope

  @config %Config{
    enabled: true,
    business_account_id: "business-123",
    phone_number_id: "phone-number-123"
  }

  test "keeps only entries and message/status changes for configured WABA and phone" do
    payload = %{
      "entry" => [
        %{
          "id" => "other-business",
          "changes" => [%{"value" => scoped_value()}]
        },
        %{
          "id" => "business-123",
          "changes" => [
            %{"value" => scoped_value()},
            %{"value" => put_in(scoped_value(), ["metadata", "phone_number_id"], "other-phone")}
          ]
        }
      ]
    }

    assert {:ok, %{"entry" => [%{"id" => "business-123", "changes" => [change]}]}} =
             WebhookScope.filter(payload, @config)

    assert change["value"]["metadata"]["phone_number_id"] == "phone-number-123"
  end

  test "ignores signed-looking events with missing or invalid scope" do
    assert {:ignore, :out_of_scope} =
             WebhookScope.filter(
               %{"entry" => [%{"id" => "business-123", "changes" => []}]},
               @config
             )

    assert {:ignore, :out_of_scope} =
             WebhookScope.filter(
               %{
                 "entry" => [
                   %{"id" => "other-business", "changes" => [%{"value" => scoped_value()}]}
                 ]
               },
               @config
             )
  end

  defp scoped_value do
    %{
      "metadata" => %{"phone_number_id" => "phone-number-123"},
      "messages" => []
    }
  end
end
