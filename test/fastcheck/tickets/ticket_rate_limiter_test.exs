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
      client_ip = "203.0.113.44"
      limit = TicketRateLimiter.exchange_token_limit()

      results =
        1..(limit + 3)
        |> Task.async_stream(
          fn _ ->
            TicketRateLimiter.check_exchange(token, client_ip)
          end,
          max_concurrency: limit + 3,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      allowed = Enum.count(results, &(&1 == :allowed))
      assert allowed == limit

      key = TicketRateLimiter.token_redis_key(token)

      {:ok, zrange_with_scores} =
        Redix.command(FastCheck.Redix, ["ZRANGE", key, 0, -1, "WITHSCORES"])

      member_score_pairs = Enum.chunk_every(zrange_with_scores, 2)
      members = Enum.map(member_score_pairs, fn [member, _score] -> member end)

      assert length(members) == limit
      assert MapSet.new(members) |> MapSet.size() == limit

      for [member, score_str] <- member_score_pairs do
        [_timestamp_part, nonce] = String.split(member, ":", parts: 2)
        score = score_str |> String.to_float() |> trunc()
        assert score > 0
        assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, nonce)
        assert byte_size(Base.url_decode64!(nonce, padding: false)) == 16
      end
    end

    test "ten concurrent customers each perform fifty unique exchanges behind one client IP" do
      shared_ip = "203.0.113.250"
      parent = self()

      tasks =
        for customer <- 1..10 do
          Task.async(fn ->
            send(parent, :ready)

            receive do
              {^parent, :go} -> :ok
            end

            for index <- 1..50 do
              token = "p1e-g-c#{customer}-i#{index}-#{System.unique_integer([:positive])}"

              assert :allowed = TicketRateLimiter.check_exchange(token, shared_ip)
            end

            :ok
          end)
        end

      for _ <- 1..10, do: assert_receive(:ready, 5_000)

      for task <- tasks, do: send(task.pid, {parent, :go})

      results = Task.await_many(tasks, 120_000)
      assert Enum.all?(results, &(&1 == :ok))

      ip_key = TicketRateLimiter.ip_redis_key(shared_ip)
      {:ok, count} = Redix.command(FastCheck.Redix, ["ZCARD", ip_key])
      assert count == 500
    end

    test "rate limiter sliding window remains Redis TIME authoritative" do
      source = File.read!("lib/fastcheck/tickets/ticket_rate_limiter.ex")

      assert source =~ "redis.call('TIME')"
      refute source =~ "System.system_time"
      refute source =~ "System.os_time"
      refute source =~ "DateTime.utc_now"

      token = "redis-time-#{System.unique_integer([:positive])}"
      key = TicketRateLimiter.token_redis_key(token)

      redis_before = redis_now_usec()
      assert :allowed = TicketRateLimiter.check_exchange(token, @client_ip)
      redis_after = redis_now_usec()

      {:ok, [_member, score_str]} =
        Redix.command(FastCheck.Redix, ["ZRANGE", key, 0, -1, "WITHSCORES"])

      score = score_str |> String.to_float() |> trunc()
      assert score >= redis_before
      assert score <= redis_after
    end

    test "independent Redix clients share one exchange token bucket" do
      secondary = :p1e_g_secondary_redix
      redis_url = Application.fetch_env!(:fastcheck, :redis_url)

      {:ok, _pid} = Redix.start_link(redis_url, name: secondary)

      on_exit(fn ->
        if pid = Process.whereis(secondary) do
          Redix.stop(pid)
        end
      end)

      token = "shared-redix-#{System.unique_integer([:positive])}"
      client_ip = "203.0.113.251"

      assert :allowed =
               TicketRateLimiter.check_exchange(token, client_ip, redix_name: FastCheck.Redix)

      assert :allowed = TicketRateLimiter.check_exchange(token, client_ip, redix_name: secondary)

      assert :allowed =
               TicketRateLimiter.check_exchange(token, client_ip, redix_name: FastCheck.Redix)

      assert :allowed = TicketRateLimiter.check_exchange(token, client_ip, redix_name: secondary)

      assert :allowed =
               TicketRateLimiter.check_exchange(token, client_ip, redix_name: FastCheck.Redix)

      assert {:rate_limited, _} =
               TicketRateLimiter.check_exchange(token, client_ip, redix_name: secondary)
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
