defmodule FastCheck.Diagnostics.Tickera do
  @moduledoc """
  Runtime probe utilities for validating Tickera endpoint behavior.

  Intended for release debugging via:
    bin/fastcheck eval "FastCheck.Diagnostics.Tickera.probe(\"https://example.com\", \"API_KEY\")"
  """

  alias Req.Response

  @timeout 30_000

  @spec probe(String.t(), String.t()) :: map()
  def probe(site_url, api_key) when is_binary(site_url) and is_binary(api_key) do
    normalized_site_url = normalize_site_url(site_url)

    endpoints = [
      {"check_credentials", "check_credentials"},
      {"event_essentials", "event_essentials"},
      {"tickets_info_page_1", "tickets_info/100/1/"}
    ]

    report =
      Enum.reduce(endpoints, %{}, fn {label, endpoint}, acc ->
        Map.put(acc, label, probe_endpoint(normalized_site_url, api_key, endpoint))
      end)

    IO.inspect(report, label: "Tickera probe report")
    report
  end

  def probe(_site_url, _api_key) do
    report = %{error: "site_url and api_key must be binaries"}
    IO.inspect(report, label: "Tickera probe report")
    report
  end

  defp probe_endpoint(site_url, api_key, endpoint) do
    url = build_url(site_url, api_key, endpoint)

    case Req.request(
           method: :get,
           url: url,
           headers: [{"accept", "application/json"}],
           decode_body: false,
           connect_options: [timeout: @timeout],
           receive_timeout: @timeout
         ) do
      {:ok, %Response{status: status, headers: headers, body: body}} ->
        body_bin = normalize_body(body)
        parsed = parse_json(body_bin)

        %{
          status: status,
          url: safe_url(url),
          content_type: header(headers, "content-type"),
          location: header(headers, "location"),
          body_bytes: byte_size(body_bin),
          body_preview: String.slice(body_bin, 0, 300),
          json: parsed
        }

      {:error, reason} ->
        %{
          url: safe_url(url),
          error: inspect(reason)
        }
    end
  end

  defp parse_json(""), do: %{decodable: false, reason: "empty_body"}

  defp parse_json(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} ->
        %{
          decodable: true,
          type: "map",
          top_level_keys: Map.keys(map)
        }

      {:ok, list} when is_list(list) ->
        %{
          decodable: true,
          type: "list",
          length: length(list)
        }

      {:ok, other} ->
        %{
          decodable: true,
          type: "scalar",
          value_preview: inspect(other)
        }

      {:error, error} ->
        %{
          decodable: false,
          reason: inspect(error)
        }
    end
  end

  defp normalize_site_url(site_url) do
    trimmed = String.trim(site_url)

    case Regex.match?(~r/^https?:\/\//i, trimmed) do
      true -> String.trim_trailing(trimmed, "/")
      false -> "https://#{String.trim_trailing(trimmed, "/")}"
    end
  end

  defp build_url(site_url, api_key, endpoint) do
    endpoint = endpoint |> to_string() |> String.trim_leading("/")
    "#{site_url}/tc-api/#{api_key}/#{endpoint}"
  end

  defp safe_url(url) do
    Regex.replace(~r{/tc-api/[^/?#]+}, url, "/tc-api/[REDACTED]")
  end

  defp header(headers, key) do
    downcased = String.downcase(key)

    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == downcased do
        to_string(value)
      end
    end)
  end

  defp normalize_body(body) when is_binary(body), do: String.trim(body)

  defp normalize_body(body) when is_map(body) do
    case Jason.encode(body) do
      {:ok, encoded} -> String.trim(encoded)
      {:error, _reason} -> ""
    end
  end

  defp normalize_body(body) when is_list(body) do
    body
    |> IO.iodata_to_binary()
    |> String.trim()
  rescue
    ArgumentError ->
      case Jason.encode(body) do
        {:ok, encoded} -> String.trim(encoded)
        {:error, _reason} -> ""
      end
  end

  defp normalize_body(nil), do: ""
  defp normalize_body(_body), do: ""
end
