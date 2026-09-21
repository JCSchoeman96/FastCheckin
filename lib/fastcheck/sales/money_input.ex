defmodule FastCheck.Sales.MoneyInput do
  @moduledoc """
  Exact ZAR money parsing for admin Sales offer management.

  Converts major-unit strings such as `100`, `100.00`, and `99.95` to integer cents
  without floating-point arithmetic.
  """

  @max_cents 999_999_999

  @spec parse_zar_to_cents(String.t()) :: {:ok, non_neg_integer()} | {:error, :invalid_money}
  def parse_zar_to_cents(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, :invalid_money}

      not Regex.match?(~r/^\d+(?:\.\d{1,2})?$/, trimmed) ->
        {:error, :invalid_money}

      true ->
        case String.split(trimmed, ".", parts: 2) do
          [whole] ->
            parse_whole_units(whole)

          [whole, fraction] ->
            with {:ok, whole_cents} <- parse_whole_units(whole),
                 {:ok, fraction_cents} <- parse_fraction_units(fraction) do
              add_cents(whole_cents, fraction_cents)
            end
        end
    end
  end

  def parse_zar_to_cents(_), do: {:error, :invalid_money}

  @spec format_cents_as_zar(non_neg_integer()) :: String.t()
  def format_cents_as_zar(cents) when is_integer(cents) and cents >= 0 do
    whole = div(cents, 100)
    fraction = rem(cents, 100)

    if fraction == 0 do
      Integer.to_string(whole)
    else
      Integer.to_string(whole) <> "." <> String.pad_leading(Integer.to_string(fraction), 2, "0")
    end
  end

  defp parse_whole_units(whole) do
    case Integer.parse(whole) do
      {units, ""} when units >= 0 ->
        cents = units * 100

        if cents > @max_cents, do: {:error, :invalid_money}, else: {:ok, cents}

      _ ->
        {:error, :invalid_money}
    end
  end

  defp parse_fraction_units(fraction) do
    padded = String.pad_trailing(fraction, 2, "0")

    case Integer.parse(padded) do
      {units, ""} when units >= 0 and units < 100 -> {:ok, units}
      _ -> {:error, :invalid_money}
    end
  end

  defp add_cents(whole_cents, fraction_cents) do
    total = whole_cents + fraction_cents

    if total > @max_cents, do: {:error, :invalid_money}, else: {:ok, total}
  end
end
