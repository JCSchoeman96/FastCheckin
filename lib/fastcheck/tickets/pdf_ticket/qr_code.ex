defmodule FastCheck.Tickets.PdfTicket.QrCode do
  @moduledoc """
  QR draw data for PDF ticket rendering.

  This module is the only place that knows how the `EQRCode` dependency exposes
  matrix data. It accepts only the already-resolved scanner payload and never
  hashes, tokenizes, logs, or stores that source value.
  """

  @enforce_keys [:format, :size, :modules, :dark_module_count]
  defstruct @enforce_keys

  @type module_value :: 0 | 1
  @type t :: %__MODULE__{
          format: :matrix,
          size: pos_integer(),
          modules: [[module_value()]],
          dark_module_count: non_neg_integer()
        }

  @spec from_payload(term()) ::
          {:ok, t()} | {:error, :blank_payload | :malformed_payload | :generation_failed}
  def from_payload(payload) when is_binary(payload) do
    cond do
      payload == "" or String.trim(payload) == "" ->
        {:error, :blank_payload}

      payload != String.trim(payload) ->
        {:error, :malformed_payload}

      payload_control_characters?(payload) ->
        {:error, :malformed_payload}

      true ->
        build_matrix(payload)
    end
  end

  def from_payload(nil), do: {:error, :blank_payload}
  def from_payload(_payload), do: {:error, :malformed_payload}

  defp payload_control_characters?(payload) do
    Regex.match?(~r/[\x00-\x1F\x7F]/, payload)
  end

  defp build_matrix(payload) do
    payload
    |> EQRCode.encode(:m)
    |> normalize_matrix()
  rescue
    _error -> {:error, :generation_failed}
  end

  defp normalize_matrix(%{matrix: matrix}) when is_tuple(matrix) do
    modules =
      matrix
      |> Tuple.to_list()
      |> Enum.map(&normalize_row/1)

    size = length(modules)

    with true <- size > 0,
         true <- Enum.all?(modules, &(length(&1) == size)),
         dark_module_count when dark_module_count > 0 <- count_dark_modules(modules) do
      {:ok,
       %__MODULE__{
         format: :matrix,
         size: size,
         modules: modules,
         dark_module_count: dark_module_count
       }}
    else
      _other -> {:error, :generation_failed}
    end
  end

  defp normalize_matrix(_matrix), do: {:error, :generation_failed}

  defp normalize_row(row) when is_tuple(row) do
    row
    |> Tuple.to_list()
    |> Enum.map(&normalize_module/1)
  end

  defp normalize_row(_row), do: []

  defp normalize_module(1), do: 1
  defp normalize_module(true), do: 1
  defp normalize_module(_value), do: 0

  defp count_dark_modules(modules) do
    modules
    |> List.flatten()
    |> Enum.count(&(&1 == 1))
  end
end

defimpl Inspect, for: FastCheck.Tickets.PdfTicket.QrCode do
  def inspect(qr_code, opts) do
    %{
      format: qr_code.format,
      size: qr_code.size,
      dark_module_count: qr_code.dark_module_count
    }
    |> Inspect.Map.inspect(opts)
  end
end
