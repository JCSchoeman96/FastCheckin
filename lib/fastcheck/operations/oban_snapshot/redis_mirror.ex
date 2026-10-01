defmodule FastCheck.Operations.ObanSnapshot.RedisMirror do
  @moduledoc """
  Namespaced Redis coordination and snapshot distribution for P1-F.
  """

  alias FastCheck.Redis
  alias FastCheck.Redis.Namespace

  @snapshot_key "fastcheck:ops:oban:snapshot"
  @lease_key "fastcheck:ops:oban:collect_lease"
  @lease_ttl_ms 14_000
  @snapshot_ttl_seconds 60

  @spec acquire_lease(String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def acquire_lease(node_id, opts \\ []) when is_binary(node_id) do
    command_fun = Keyword.get(opts, :command_fun, &Redis.command/2)

    command = [
      "SET",
      Namespace.key(@lease_key),
      node_id,
      "NX",
      "PX",
      Integer.to_string(@lease_ttl_ms)
    ]

    case command_fun.(command, fallback: false) do
      {:ok, "OK"} -> {:ok, true}
      {:ok, nil} -> {:ok, false}
      {:ok, false} -> {:ok, false}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_lease_response}
    end
  end

  @spec write_snapshot(map(), keyword()) :: :ok | {:error, term()}
  def write_snapshot(snapshot, opts \\ []) do
    command_fun = Keyword.get(opts, :command_fun, &Redis.command/2)

    with {:ok, payload} <- Jason.encode(snapshot),
         {:ok, "OK"} <-
           command_fun.(
             [
               "SET",
               Namespace.key(@snapshot_key),
               payload,
               "EX",
               Integer.to_string(@snapshot_ttl_seconds)
             ],
             fallback: false
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_snapshot_write_response}
    end
  end

  @spec read_snapshot(keyword()) :: {:ok, map() | nil} | {:error, term()}
  def read_snapshot(opts \\ []) do
    command_fun = Keyword.get(opts, :command_fun, &Redis.command/2)

    case command_fun.(["GET", Namespace.key(@snapshot_key)], fallback: false) do
      {:ok, nil} -> {:ok, nil}
      {:ok, payload} when is_binary(payload) -> Jason.decode(payload)
      {:ok, _payload} -> {:error, :invalid_snapshot_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec snapshot_key() :: String.t()
  def snapshot_key, do: Namespace.key(@snapshot_key)

  @spec lease_key() :: String.t()
  def lease_key, do: Namespace.key(@lease_key)

  @spec lease_ttl_ms() :: pos_integer()
  def lease_ttl_ms, do: @lease_ttl_ms

  @spec snapshot_ttl_seconds() :: pos_integer()
  def snapshot_ttl_seconds, do: @snapshot_ttl_seconds
end
