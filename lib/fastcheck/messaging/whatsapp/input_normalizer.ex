defmodule FastCheck.Messaging.WhatsApp.InputNormalizer do
  @moduledoc """
  Normalizes customer-entered WhatsApp menu input for the VS-18 number-only flow.
  """

  @max_text_length 256

  @type normalized ::
          {:number, 1..9}
          | :back
          | :restart
          | :help
          | :stop
          | {:text, String.t()}

  @spec normalize(term()) :: {:ok, normalized()} | {:error, :blank | :invalid | :too_long}
  def normalize(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, :blank}

      String.length(trimmed) > @max_text_length ->
        {:error, :too_long}

      trimmed in ~w(1 2 3 4 5 6 7 8 9) ->
        {:ok, {:number, String.to_integer(trimmed)}}

      trimmed == "0" ->
        {:ok, :back}

      trimmed == "#" ->
        {:ok, :restart}

      String.downcase(trimmed) == "help" ->
        {:ok, :help}

      String.downcase(trimmed) == "stop" ->
        {:ok, :stop}

      Regex.match?(~r/^\d+$/, trimmed) ->
        {:error, :invalid}

      true ->
        {:ok, {:text, trimmed}}
    end
  end

  def normalize(_value), do: {:error, :invalid}
end
