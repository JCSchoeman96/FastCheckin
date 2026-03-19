defmodule FastCheck.Redis do
  @moduledoc """
  Small Redis command wrapper for scaffolded Redis-backed helpers.

  The active mobile ingestion path calls Redis without fallback. Legacy
  scaffolded helpers can still opt into the ETS fallback for local development.
  """

  @ets_table :fastcheck_redis_fallback
  @redix_name FastCheck.Redix

  @spec command([String.t()], Keyword.t()) :: {:ok, term()} | {:error, term()}
  def command(command, opts \\ [])

  def command(command, opts) when is_list(command) do
    fallback? = Keyword.get(opts, :fallback, true)

    case Process.whereis(@redix_name) do
      pid when is_pid(pid) ->
        case Redix.command(@redix_name, command) do
          {:ok, _result} = ok ->
            ok

          {:error, reason} when fallback? ->
            fallback_command(command, reason)

          {:error, _reason} = error ->
            error
        end

      _ when fallback? ->
        fallback_command(command, :redis_unavailable)

      _ ->
        {:error, :redis_unavailable}
    end
  end

  def command(_command, _opts), do: {:error, :invalid_command}

  defp fallback_command(["SADD", key, member], _reason) do
    with {:ok, set} <- fetch_set(key) do
      already_present? = MapSet.member?(set, member)
      updated = MapSet.put(set, member)
      true = :ets.insert(@ets_table, {key, {:set, updated}, nil})
      {:ok, if(already_present?, do: 0, else: 1)}
    end
  end

  defp fallback_command(["SISMEMBER", key, member], _reason) do
    with {:ok, set} <- fetch_set(key) do
      {:ok, if(MapSet.member?(set, member), do: 1, else: 0)}
    end
  end

  defp fallback_command(["GET", key], _reason) do
    ensure_fallback_table()

    case lookup(key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fallback_command(["SETEX", key, ttl, value], _reason) do
    ensure_fallback_table()
    expires_at = expiry_from_ttl(ttl)
    true = :ets.insert(@ets_table, {key, value, expires_at})
    {:ok, "OK"}
  end

  defp fallback_command(["DEL", key], _reason) do
    ensure_fallback_table()
    {:ok, :ets.delete(@ets_table, key)}
  end

  defp fallback_command(_command, reason), do: {:error, reason}

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
