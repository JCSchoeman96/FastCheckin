defmodule FastCheck.Messaging.WhatsApp.ProviderStatusTest do
  use ExUnit.Case, async: true

  alias FastCheck.Messaging.WhatsApp.ProviderStatus

  test "normalizes supported statuses and keeps only bounded fields" do
    payload =
      status_payload(%{
        "id" => "wamid.tracked",
        "status" => "failed",
        "timestamp" => "1782477600",
        "recipient_id" => "27821234567",
        "errors" => [%{"code" => 131_026, "title" => "private detail"}]
      })

    assert {:ok, [%ProviderStatus{} = event]} =
             ProviderStatus.normalize(payload,
               raw_payload_hash: "payload-hash",
               correlation_id: "corr-123"
             )

    assert event.provider == "meta"
    assert event.provider_message_id == "wamid.tracked"
    assert event.status == "failed"
    assert event.provider_error_code == "131026"
    assert event.raw_payload_hash == "payload-hash"
    assert event.correlation_id == "corr-123"
    assert event.provider_timestamp == DateTime.from_unix!(1_782_477_600)
    refute inspect(event) =~ "27821234567"
    refute inspect(event) =~ "private detail"
  end

  test "ignores unsupported statuses, malformed timestamps, and oversized WAMIDs" do
    payload =
      status_payload([
        %{"id" => "bad", "status" => "sent", "timestamp" => "not-a-time"},
        %{
          "id" => String.duplicate("w", 257),
          "status" => "sent",
          "timestamp" => "1782477600"
        },
        %{"id" => "unknown", "status" => "queued", "timestamp" => "1782477600"}
      ])

    assert {:ok, []} = ProviderStatus.normalize(payload)
  end

  test "replaces unsafe correlation values with an opaque generated id" do
    assert {:ok, [%ProviderStatus{correlation_id: correlation_id}]} =
             ProviderStatus.normalize(
               status_payload(%{
                 "id" => "wamid.correlation",
                 "status" => "sent",
                 "timestamp" => "1782477600"
               }),
               correlation_id: "+27821234567"
             )

    assert correlation_id != "+27821234567"
    assert correlation_id =~ ~r/\A[A-Za-z0-9_-]+\z/
  end

  defp status_payload(statuses) when is_map(statuses), do: status_payload([statuses])

  defp status_payload(statuses) when is_list(statuses) do
    %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{"statuses" => statuses}
            }
          ]
        }
      ]
    }
  end
end
