defmodule FastCheck.Redis do
  @moduledoc """
  Small Redis command wrapper for the native scanner scaffold.

  It prefers a live Redis connection through Redix and falls back to ETS when
  Redis is unavailable so local development and tests can still exercise the
  contract.
  """

  @ets_table :fastcheck_redis_fallback
  @redix_name FastCheck.Redix

  @spec command([String.t()]) :: {:ok, term()} | {:error, term()}
  def command(command) when is_list(command) do
    case ensure_connection() do
      {:ok, _pid} ->
        Redix.command(@redix_name, command)

      {:error, _reason} ->
        fallback_command(command)
    end
  end

  def command(_command), do: {:error, :invalid_command}

  defp ensure_connection do
    case Process.whereis(@redix_name) do
      nil ->
        redis_url = Application.get_env(:fastcheck, :redis_url, "redis://localhost:6379")

        case Redix.start_link(redis_url, name: @redix_name) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  defp fallback_command(["SADD", key, member]) do
    with {:ok, set} <- fetch_set(key) do
      already_present? = MapSet.member?(set, member)
      updated = MapSet.put(set, member)
      true = :ets.insert(@ets_table, {key, {:set, updated}, nil})
      {:ok, if(already_present?, do: 0, else: 1)}
    end
  end

  defp fallback_command(["SISMEMBER", key, member]) do
    with {:ok, set} <- fetch_set(key) do
      {:ok, if(MapSet.member?(set, member), do: 1, else: 0)}
    end
  end

  defp fallback_command(["GET", key]) do
    ensure_fallback_table()

    case lookup(key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fallback_command(["SETEX", key, ttl, value]) do
    ensure_fallback_table()
    expires_at = expiry_from_ttl(ttl)
    true = :ets.insert(@ets_table, {key, value, expires_at})
    {:ok, "OK"}
  end

  defp fallback_command(["DEL", key]) do
    ensure_fallback_table()
    {:ok, :ets.delete(@ets_table, key)}
  end

  defp fallback_command(_command), do: {:error, :unsupported_fallback_command}

  defp fetch_set(key) do
    ensure_fallback_table()

    case lookup(key) do
      {:ok, {:set, %MapSet{} = set}} -> {:ok, set}
      {:ok, _other} -> {:ok, MapSet.new()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lookup(key) do
    ensure_fallback_table()

    case :ets.lookup(@ets_table, key) do
      [{^key, value, expires_at}] ->
        if expired?(expires_at) do
          :ets.delete(@ets_table, key)
          {:ok, nil}
        else
          {:ok, value}
        end

      [] ->
        {:ok, nil}
    end
  rescue
    exception -> {:error, exception}
  end

  defp expired?(nil), do: false
  defp expired?(expires_at), do: System.system_time(:second) >= expires_at

  defp expiry_from_ttl(ttl) when is_binary(ttl) do
    case Integer.parse(ttl) do
      {seconds, ""} when seconds > 0 -> System.system_time(:second) + seconds
      _ -> nil
    end
  end

  defp expiry_from_ttl(ttl) when is_integer(ttl) and ttl > 0,
    do: System.system_time(:second) + ttl

  defp expiry_from_ttl(_ttl), do: nil

  defp ensure_fallback_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true])

      _tid ->
        :ok
    end
  end
end
