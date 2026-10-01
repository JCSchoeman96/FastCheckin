defmodule FastCheck.Operations.ObanSnapshot.Clock do
  @moduledoc """
  Injectable UTC wall clock for Oban snapshot timestamps and freshness.
  """

  @config_key :operations_oban_clock

  @spec utc_now() :: DateTime.t()
  def utc_now do
    case Application.get_env(:fastcheck, @config_key) do
      fun when is_function(fun, 0) ->
        fun.()

      module when is_atom(module) and not is_nil(module) ->
        if function_exported?(module, :utc_now, 0), do: module.utc_now(), else: DateTime.utc_now()

      _ ->
        DateTime.utc_now()
    end
  end

  @spec monotonic_time() :: integer()
  def monotonic_time, do: System.monotonic_time(:millisecond)
end
