defmodule FastCheckWeb.ClientIp do
  @moduledoc """
  Trusted client IP for P1-E secure-ticket exchange rate limits.

  Uses `CF-Connecting-IP` only when the outer peer (`X-Real-IP` or direct
  connection) belongs to configured Cloudflare proxy CIDRs. Never trusts
  `X-Forwarded-For`.
  """

  @type cidr :: {family :: :inet | :inet6, network :: :inet.ip_address(), prefix :: pos_integer()}

  @doc "Returns the trusted client IP string for rate limiting and exchange guards."
  @spec from_conn(Plug.Conn.t()) :: String.t()
  def from_conn(conn) do
    outer = outer_peer(conn)

    if outer_trusted_cloudflare?(outer) do
      case single_valid_ip_header(conn, "cf-connecting-ip") do
        {:ok, client_ip} -> client_ip
        :error -> outer
      end
    else
      outer
    end
  end

  @doc false
  @spec trusted_cloudflare_proxy_cidrs() :: [cidr()]
  def trusted_cloudflare_proxy_cidrs do
    Application.get_env(:fastcheck, __MODULE__, [])
    |> Keyword.get(:trusted_cloudflare_proxy_cidrs, [])
  end

  @doc """
  Parses comma-separated CIDR strings for runtime configuration.

  Raises `ArgumentError` when any entry is malformed or prefix is out of range.
  """
  @spec parse_trusted_cloudflare_proxy_cidrs!(String.t() | nil) :: [cidr()]
  def parse_trusted_cloudflare_proxy_cidrs!(nil), do: []
  def parse_trusted_cloudflare_proxy_cidrs!(""), do: []

  def parse_trusted_cloudflare_proxy_cidrs!(raw) when is_binary(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_cidr!/1)
  end

  defp outer_peer(conn) do
    case single_valid_ip_header(conn, "x-real-ip") do
      {:ok, ip} -> ip
      :error -> plug_peer_ip(conn)
    end
  end

  defp plug_peer_ip(conn) do
    %{address: address} = Plug.Conn.get_peer_data(conn)
    address |> :inet.ntoa() |> to_string()
  end

  defp single_valid_ip_header(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [value | _] ->
        trimmed = String.trim(value)

        if trimmed != "" and not String.contains?(trimmed, ",") do
          case parse_ip(trimmed) do
            {:ok, _tuple} -> {:ok, trimmed}
            :error -> :error
          end
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp outer_trusted_cloudflare?(outer_ip) do
    case parse_ip(outer_ip) do
      {:ok, tuple} -> ip_in_any_cidr?(tuple, trusted_cloudflare_proxy_cidrs())
      :error -> false
    end
  end

  defp ip_in_any_cidr?(ip_tuple, cidrs) do
    Enum.any?(cidrs, fn cidr -> ip_in_cidr?(ip_tuple, cidr) end)
  end

  defp ip_in_cidr?(ip_tuple, {family, network, prefix}) do
    network_list = Tuple.to_list(network)
    ip_list = Tuple.to_list(ip_tuple)

    case family do
      :inet -> ip_in_cidr_ipv4(ip_list, network_list, prefix)
      :inet6 -> ip_in_cidr_ipv6(ip_list, network_list, prefix)
    end
  end

  defp ip_in_cidr_ipv4(ip, network, prefix) when prefix >= 0 and prefix <= 32 do
    ip_int = ipv4_to_int(ip)
    net_int = ipv4_to_int(Tuple.to_list(network))

    mask =
      if prefix == 0,
        do: 0,
        else: Bitwise.bsl(0xFFFFFFFF, 32 - prefix) |> Bitwise.band(0xFFFFFFFF)

    Bitwise.band(ip_int, mask) == Bitwise.band(net_int, mask)
  end

  defp ip_in_cidr_ipv4(_ip, _network, _prefix), do: false

  defp ip_in_cidr_ipv6(ip, network, prefix) when prefix >= 0 and prefix <= 128 do
    ip_bits = ipv6_to_bitstring(ip)
    net_bits = ipv6_to_bitstring(Tuple.to_list(network))
    take_prefix(ip_bits, prefix) == take_prefix(net_bits, prefix)
  end

  defp ip_in_cidr_ipv6(_ip, _network, _prefix), do: false

  defp ipv4_to_int([a, b, c, d]) do
    Bitwise.bsl(a, 24) + Bitwise.bsl(b, 16) + Bitwise.bsl(c, 8) + d
  end

  defp ipv6_to_bitstring(bytes) do
    Enum.map_join(bytes, "", &(Integer.to_string(&1, 2) |> String.pad_leading(8, "0")))
  end

  defp take_prefix(bitstring, prefix) do
    String.slice(bitstring, 0, prefix)
  end

  defp parse_cidr!(entry) do
    case String.split(entry, "/", parts: 2) do
      [ip_part, prefix_part] ->
        with {:ok, ip_tuple} <- parse_ip(String.trim(ip_part)),
             {prefix, ""} <- Integer.parse(String.trim(prefix_part)),
             family <- ip_family(ip_tuple),
             true <- valid_prefix?(family, prefix) do
          {family, ip_tuple, prefix}
        else
          _ -> raise ArgumentError, "invalid Cloudflare proxy CIDR: #{entry}"
        end

      _ ->
        raise ArgumentError, "invalid Cloudflare proxy CIDR: #{entry}"
    end
  end

  defp ip_family(tuple) when tuple_size(tuple) == 4, do: :inet
  defp ip_family(tuple) when tuple_size(tuple) == 8, do: :inet6

  defp valid_prefix?(:inet, prefix), do: prefix >= 0 and prefix <= 32
  defp valid_prefix?(:inet6, prefix), do: prefix >= 0 and prefix <= 128
  defp valid_prefix?(_, _), do: false

  defp parse_ip(string) do
    case :inet.parse_address(String.to_charlist(string)) do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _} -> :error
    end
  end
end
