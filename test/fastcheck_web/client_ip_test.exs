defmodule FastCheckWeb.ClientIpTest do
  use ExUnit.Case, async: true

  alias FastCheckWeb.ClientIp

  setup do
    previous = Application.get_env(:fastcheck, ClientIp, [])

    on_exit(fn ->
      Application.put_env(:fastcheck, ClientIp, previous)
    end)

    :ok
  end

  defp conn_with(headers, peer \\ {127, 0, 0, 1}) do
    conn =
      Plug.Test.conn(:get, "/t/session")
      |> Map.put(:remote_ip, peer)

    Enum.reduce(headers, conn, fn {k, v}, c ->
      Plug.Conn.put_req_header(c, k, v)
    end)
  end

  defp put_trusted_cidrs(cidrs) do
    Application.put_env(:fastcheck, ClientIp, trusted_cloudflare_proxy_cidrs: cidrs)
  end

  test "trusted CF IPv4 outer and valid CF-Connecting-IP yields visitor IP" do
    put_trusted_cidrs([{:inet, {173, 245, 48, 0}, 20}])

    conn =
      conn_with([
        {"x-real-ip", "173.245.48.10"},
        {"cf-connecting-ip", "203.0.113.50"}
      ])

    assert ClientIp.from_conn(conn) == "203.0.113.50"
  end

  test "trusted CF IPv6 outer and valid CF-Connecting-IP yields visitor IP" do
    put_trusted_cidrs([
      {:inet6, {2_603, 47_00, 0x50B0, 0, 0, 0, 0, 0}, 32}
    ])

    conn =
      conn_with(
        [
          {"x-real-ip", "2603:4700:50b0::1"},
          {"cf-connecting-ip", "2001:db8::5"}
        ],
        {0, 0, 0, 0, 0, 0, 0, 1}
      )

    assert ClientIp.from_conn(conn) == "2001:db8::5"
  end

  test "untrusted outer ignores spoofed CF-Connecting-IP" do
    put_trusted_cidrs([{:inet, {173, 245, 48, 0}, 20}])

    conn =
      conn_with([
        {"x-real-ip", "203.0.113.9"},
        {"cf-connecting-ip", "198.51.100.1"}
      ])

    assert ClientIp.from_conn(conn) == "203.0.113.9"
  end

  test "invalid CF-Connecting-IP falls back to outer peer" do
    put_trusted_cidrs([{:inet, {173, 245, 48, 0}, 20}])

    conn =
      conn_with([
        {"x-real-ip", "173.245.48.10"},
        {"cf-connecting-ip", "not-an-ip"}
      ])

    assert ClientIp.from_conn(conn) == "173.245.48.10"
  end

  test "missing CF-Connecting-IP falls back to outer peer" do
    put_trusted_cidrs([{:inet, {173, 245, 48, 0}, 20}])

    conn = conn_with([{"x-real-ip", "173.245.48.10"}])
    assert ClientIp.from_conn(conn) == "173.245.48.10"
  end

  test "invalid X-Real-IP falls back to plug peer" do
    put_trusted_cidrs([])

    conn =
      conn_with([{"x-real-ip", "bogus"}, {"x-forwarded-for", "198.51.100.99"}])

    assert ClientIp.from_conn(conn) == "127.0.0.1"
  end

  test "X-Forwarded-For attacker value is ignored" do
    put_trusted_cidrs([])

    conn =
      conn_with([
        {"x-forwarded-for", "198.51.100.99"},
        {"cf-connecting-ip", "198.51.100.99"}
      ])

    assert ClientIp.from_conn(conn) == "127.0.0.1"
  end

  test "parse_trusted_cloudflare_proxy_cidrs! validates IPv4 membership helpers" do
    cidrs = ClientIp.parse_trusted_cloudflare_proxy_cidrs!("203.0.113.0/24")
    assert cidrs == [{:inet, {203, 0, 113, 0}, 24}]
  end

  test "parse_trusted_cloudflare_proxy_cidrs! validates IPv6" do
    cidrs = ClientIp.parse_trusted_cloudflare_proxy_cidrs!("2001:db8::/32")
    assert [{:inet6, _, 32}] = cidrs
  end

  test "out-of-range CIDR prefix is rejected" do
    assert_raise ArgumentError, fn ->
      ClientIp.parse_trusted_cloudflare_proxy_cidrs!("203.0.113.0/33")
    end

    assert_raise ArgumentError, fn ->
      ClientIp.parse_trusted_cloudflare_proxy_cidrs!("2001:db8::/129")
    end
  end

  test "malformed CIDR is rejected" do
    assert_raise ArgumentError, fn ->
      ClientIp.parse_trusted_cloudflare_proxy_cidrs!("not-a-cidr")
    end
  end
end
