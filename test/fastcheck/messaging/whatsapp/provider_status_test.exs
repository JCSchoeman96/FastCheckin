defmodule FastCheck.Messaging.WhatsApp.ProviderStatusTest do
  use ExUnit.Case, async: true

  alias FastCheck.Messaging.WhatsApp.ProviderStatus

  test "normalizes allowed status evidence without retaining recipient data" do
    payload = %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "statuses" => [
                  %{
                    "id" => "wamid.tracked",
                    "status" => "failed",
                    "timestamp" => "1782477600",
                    "recipient_id" => "27821234567",
                    "errors" => [%{"code" => 131_026, "title" => "private failure detail"}]
                  },
                  %{"id" => "wamid.ignored", "status" => "unknown", "timestamp" => "1782477600"}
                ]
              }
            }
          ]
        }
      ]
    }

    assert {:ok, [%ProviderStatus{} = event]} =
             ProviderStatus.normalize(payload, raw_payload_hash: "hash", correlation_id: "corr")

    assert event.provider == "meta"
    assert event.provider_message_id == "wamid.tracked"
    assert event.status == "failed"
    assert event.provider_error_code == "131026"
    assert event.raw_payload_hash == "hash"
    refute inspect(event) =~ "27821234567"
    refute inspect(event) =~ "private failure detail"
  end

  test "malformed timestamps and oversized ids are ignored safely" do
    payload = %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "statuses" => [
                  %{"id" => "bad-time", "status" => "sent", "timestamp" => "not-a-time"},
                  %{
                    "id" => String.duplicate("w", 257),
                    "status" => "sent",
                    "timestamp" => "1782477600"
                  }
                ]
              }
            }
          ]
        }
      ]
    }

    assert {:ok, []} = ProviderStatus.normalize(payload)
  end

  test "untrusted correlation values are replaced with an opaque generated id" do
    payload = %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "statuses" => [
                  %{"id" => "wamid.correlation", "status" => "sent", "timestamp" => "1782477600"}
                ]
              }
            }
          ]
        }
      ]
    }

    assert {:ok, [%ProviderStatus{correlation_id: correlation_id}]} =
             ProviderStatus.normalize(payload, correlation_id: "+27821234567")

    refute correlation_id == "+27821234567"
    assert correlation_id =~ ~r/\A[A-Za-z0-9_-]+\z/
  end
end
