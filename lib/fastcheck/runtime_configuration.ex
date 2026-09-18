defmodule FastCheck.RuntimeConfiguration do
  @moduledoc """
  Small pure helpers for fail-closed production runtime configuration.
  """

  @strict_true ["1", "true", "yes", "on"]
  @strict_false ["0", "false", "no", "off"]

  @spec whatsapp_sandbox_mode(atom(), boolean(), term()) ::
          {:ok, boolean()} | {:error, :missing | :invalid}
  def whatsapp_sandbox_mode(environment, whatsapp_enabled, raw_value) do
    cond do
      environment == :prod and whatsapp_enabled and blank?(raw_value) ->
        {:error, :missing}

      blank?(raw_value) ->
        {:ok, true}

      true ->
        case strict_boolean(raw_value) do
          {:ok, value} ->
            {:ok, value}

          :error ->
            if environment == :prod and whatsapp_enabled,
              do: {:error, :invalid},
              else: {:ok, false}
        end
    end
  end

  defp strict_boolean(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      value when value in @strict_true -> {:ok, true}
      value when value in @strict_false -> {:ok, false}
      _ -> :error
    end
  end

  defp strict_boolean(_value), do: :error

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
