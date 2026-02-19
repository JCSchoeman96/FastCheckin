defmodule FastCheck.TickeraClientTest do
  use ExUnit.Case, async: false

  alias FastCheck.TickeraClient
  alias FastCheck.TickeraClient.Fallback
  alias Req.Request
  alias Req.Response

  setup do
    previous_request_fun = Application.get_env(:fastcheck, :tickera_request_fun)

    on_exit(fn ->
      if is_nil(previous_request_fun) do
        Application.delete_env(:fastcheck, :tickera_request_fun)
      else
        Application.put_env(:fastcheck, :tickera_request_fun, previous_request_fun)
      end
    end)

    :ok
  end

  test "retries empty-body responses with fallback request profile" do
    requests_key = {:tickera_mock_requests, make_ref()}
    responses_key = {:tickera_mock_responses, make_ref()}

    set_request_sequence(
      [
        {:ok, %Response{status: 200, body: "", headers: [{"content-length", "0"}]}},
        {:ok, %Response{status: 200, body: "", headers: [{"content-length", "0"}]}},
        {:ok,
         %Response{
           status: 200,
           body: ~s({"pass":true,"event_name":"Voelgoed Live"}),
           headers: [{"content-type", "application/json"}]
         }}
      ],
      requests_key,
      responses_key
    )

    assert {:ok, payload} = TickeraClient.get_event_essentials("https://example.com", "api-123")
    assert payload["event_name"] == "Voelgoed Live"

    requests = Process.get(requests_key, []) |> Enum.reverse()
    assert length(requests) == 3

    fallback_request = Enum.at(requests, 2)
    assert ["Bearer api-123"] == Request.get_header(fallback_request, "authorization")
    assert ["identity"] == Request.get_header(fallback_request, "accept-encoding")
    assert String.ends_with?(fallback_request.url.path, "/")
    assert String.contains?(fallback_request.url.query || "", "_fc=")
  end

  test "returns empty_body after exhausting all empty-body retries" do
    requests_key = {:tickera_mock_requests, make_ref()}
    responses_key = {:tickera_mock_responses, make_ref()}

    set_request_sequence(
      [
        {:ok, %Response{status: 200, body: "", headers: []}},
        {:ok, %Response{status: 200, body: "", headers: []}},
        {:ok, %Response{status: 200, body: "", headers: [{"server", "cloudflare"}]}}
      ],
      requests_key,
      responses_key
    )

    assert {:error, {:http_error, :empty_body, hint}} =
             TickeraClient.get_tickets_info("https://example.com", "api-456", 100, 1)

    assert hint =~ "empty body"
    assert hint =~ "server=cloudflare"
  end

  test "treats empty-body errors as fallback-eligible" do
    assert Fallback.unreachable?({:http_error, :empty_body, ""})
  end

  test "parse_attendee prefers order/payment status over generic status" do
    parsed =
      TickeraClient.parse_attendee(%{
        "checksum" => "ABC-123",
        "status" => "unknown",
        "custom_fields" => [["Order Status", "Completed"]]
      })

    assert parsed.payment_status == "completed"
  end

  test "parse_attendee does not treat generic status as payment status" do
    parsed =
      TickeraClient.parse_attendee(%{
        "checksum" => "ABC-124",
        "status" => "unknown"
      })

    assert is_nil(parsed.payment_status)
  end

  defp set_request_sequence(responses, requests_key, responses_key) do
    Process.put(requests_key, [])
    Process.put(responses_key, responses)

    Application.put_env(:fastcheck, :tickera_request_fun, fn req ->
      Process.put(requests_key, [req | Process.get(requests_key, [])])

      case Process.get(responses_key, []) do
        [next | rest] ->
          Process.put(responses_key, rest)
          next

        [] ->
          raise "No mocked Tickera responses left in sequence"
      end
    end)
  end
end
