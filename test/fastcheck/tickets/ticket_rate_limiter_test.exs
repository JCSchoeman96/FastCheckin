defmodule FastCheck.Tickets.TicketRateLimiterTest do
  use ExUnit.Case, async: false

  alias FastCheck.Redis.Namespace
  alias FastCheck.Tickets.TicketRateLimiter
  alias FastCheck.Tickets.TicketSession

  @client_ip "203.0.113.77"

  setup do
    on_exit(fn -> cleanup_rate_keys() end)
    cleanup_rate_keys()
    :ok
  end

  describe "check_exchange/3" do
    test "same credential: attempts 1..5 allowed, 6th blocked" do
      token = "delivery-bearer-#{System.unique_integer([:positive])}"

      for _ <- 1..5 do
        assert :allowed = TicketRateLimiter.check_exchange(token, @client_ip)
      end

      assert {:rate_limited, retry_after} = TicketRateLimiter.check_exchange(token, @client_ip)
      assert retry_after >= 1
    end

    test "same client IP: 600 distinct credentials allowed, 601st blocked" do
      for i <- 1..600 do
        token = "ip-bucket-token-#{i}-#{System.unique_integer([:positive])}"
        assert :allowed = TicketRateLimiter.check_exchange(token, @client_ip)
      end

      assert {:rate_limited, _} =
               TicketRateLimiter.check_exchange(
                 "ip-bucket-overflow-#{System.unique_integer([:positive])}",
                 @client_ip
               )
    end

    test "concurrent requests admit exactly the allowed count without member collapse" do
      token = "concurrent-#{System.unique_integer([:positive])}"
      limit = TicketRateLimiter.exchange_token_limit()

      results =
        1..(limit + 3)
        |> Task.async_stream(
          fn _ ->
            TicketRateLimiter.check_exchange(
              token,
              "203.0.113.#{rem(System.unique_integer([]), 200)}"
            )
          end,
          max_concurrency: limit + 3,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      allowed = Enum.count(results, &(&1 == :allowed))
      assert allowed == limit
    end

    test "rate-limit key TTL is positive and stale ZSET members are pruned on check" do
      token = "ttl-token-#{System.unique_integer([:positive])}"
      key = TicketRateLimiter.token_redis_key(token)

      assert {:ok, 1} = Redix.command(FastCheck.Redix, ["ZADD", key, "1", "stale:member"])
      assert :allowed = TicketRateLimiter.check_exchange(token, @client_ip)

      {:ok, ttl} = Redix.command(FastCheck.Redix, ["TTL", key])
      assert ttl > 0

      {:ok, members} = Redix.command(FastCheck.Redix, ["ZRANGE", key, 0, -1])
      assert members != []
      refute Enum.member?(members, "stale:member")
      assert length(members) == 1
    end

    test "redis unavailable fails closed without ETS fallback" do
      token = "unavailable-#{System.unique_integer([:positive])}"

      assert :unavailable =
               TicketRateLimiter.check_exchange(token, @client_ip, redix_name: :missing_redix_p1e)
    end

    test "raw delivery bearer does not appear in redis keys" do
      token = "secret-bearer-#{System.unique_integer([:positive])}"
      assert :allowed = TicketRateLimiter.check_exchange(token, @client_ip)

      pattern = Namespace.pattern("rate-limit:secure-ticket:*")
      {:ok, keys} = Redix.command(FastCheck.Redix, ["KEYS", pattern])

      for key <- keys do
        refute key =~ token
      end
    end

    test "rate-limit keys are namespaced" do
      token = "namespaced-#{System.unique_integer([:positive])}"
      assert :allowed = TicketRateLimiter.check_exchange(token, @client_ip)

      key = TicketRateLimiter.token_redis_key(token)

      assert key ==
               Namespace.key(
                 "rate-limit:secure-ticket:exchange-token:#{TicketRateLimiter.credential_fingerprint(token)}"
               )
    end
  end

  describe "check_session_read/3" do
    test "same browser session: 120 reads allowed, 121st blocked" do
      session = TicketSession.new_browser_session_id()

      for _ <- 1..120 do
        assert :allowed =
                 TicketRateLimiter.check_session_read(session, @client_ip,
                   session_read_limit: 120
                 )
      end

      assert {:rate_limited, retry_after} =
               TicketRateLimiter.check_session_read(session, @client_ip, session_read_limit: 120)

      assert retry_after >= 1
    end

    test "same client IP: 1200 session reads allowed, 1201st blocked" do
      key = TicketRateLimiter.read_ip_redis_key(@client_ip)
      now_usec = redis_now_usec()

      for i <- 1..1200 do
        member = "#{now_usec + i}:ip-#{i}"
        Redix.command!(FastCheck.Redix, ["ZADD", key, Integer.to_string(now_usec + i), member])
      end

      Redix.command!(FastCheck.Redix, ["EXPIRE", key, 120])

      overflow_session = TicketSession.new_browser_session_id()

      assert {:rate_limited, _} =
               TicketRateLimiter.check_session_read(overflow_session, @client_ip,
                 session_read_limit: 120,
                 session_read_ip_limit: 1200
               )
    end

    test "session bucket is shared across different ticket issue ids" do
      session = TicketSession.new_browser_session_id()

      for _ <- 1..119 do
        assert :allowed =
                 TicketRateLimiter.check_session_read(session, @client_ip,
                   session_read_limit: 120
                 )
      end

      assert :allowed =
               TicketRateLimiter.check_session_read(session, "203.0.113.88",
                 session_read_limit: 120
               )

      assert {:rate_limited, _} =
               TicketRateLimiter.check_session_read(session, "203.0.113.89",
                 session_read_limit: 120
               )
    end

    test "raw browser session id does not appear in redis keys" do
      session = "raw-session-secret-#{System.unique_integer([:positive])}"
      assert :allowed = TicketRateLimiter.check_session_read(session, @client_ip)

      pattern = Namespace.pattern("rate-limit:secure-ticket:*")
      {:ok, keys} = Redix.command(FastCheck.Redix, ["KEYS", pattern])

      for key <- keys do
        refute key =~ session
      end

      assert TicketRateLimiter.session_read_redis_key(session) ==
               Namespace.key(
                 "rate-limit:secure-ticket:session:#{TicketSession.browser_session_redis_hash(session)}"
               )
    end

    test "redis unavailable fails closed" do
      session = TicketSession.new_browser_session_id()

      assert :unavailable =
               TicketRateLimiter.check_session_read(session, @client_ip,
                 redix_name: :missing_redix_p1e
               )
    end
  end

  defp redis_now_usec do
    {:ok, [sec, usec]} = Redix.command(FastCheck.Redix, ["TIME"])
    String.to_integer(sec) * 1_000_000 + String.to_integer(usec)
  end

  defp cleanup_rate_keys do
    pattern = Namespace.pattern("rate-limit:secure-ticket:*")

    case Redix.command(FastCheck.Redix, ["KEYS", pattern]) do
      {:ok, []} ->
        :ok

      {:ok, keys} when keys != [] ->
        _ = Redix.command(FastCheck.Redix, ["DEL" | Namespace.ensure_scoped_keys!(keys)])
        :ok

      _ ->
        :ok
    end
  end
end
