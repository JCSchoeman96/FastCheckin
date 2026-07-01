defmodule FastCheck.Tickets.PdfTicket.Document do
  @moduledoc """
  Safe PDF ticket output contract.

  The PDF binary is available as data for callers, but inspection is restricted
  to metadata so ticket codes and raw bytes do not leak through logs.
  """

  @content_type "application/pdf"
  @filename "fastcheck-ticket.pdf"

  @enforce_keys [:content_type, :filename, :binary, :byte_size, :generated_at, :sha256]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          content_type: String.t(),
          filename: String.t(),
          binary: binary(),
          byte_size: non_neg_integer(),
          generated_at: DateTime.t(),
          sha256: String.t()
        }

  @spec new(term(), DateTime.t()) :: {:ok, t()} | {:error, :invalid_pdf}
  def new(binary, generated_at \\ DateTime.utc_now())

  def new(binary, %DateTime{} = generated_at)
      when is_binary(binary) and byte_size(binary) >= 5 do
    if String.starts_with?(binary, "%PDF-") do
      {:ok,
       %__MODULE__{
         content_type: @content_type,
         filename: @filename,
         binary: binary,
         byte_size: byte_size(binary),
         generated_at: DateTime.truncate(generated_at, :second),
         sha256: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
       }}
    else
      {:error, :invalid_pdf}
    end
  end

  def new(_binary, _generated_at), do: {:error, :invalid_pdf}
end

defimpl Inspect, for: FastCheck.Tickets.PdfTicket.Document do
  def inspect(document, opts) do
    %{
      content_type: document.content_type,
      filename: document.filename,
      byte_size: document.byte_size,
      generated_at: document.generated_at,
      sha256: document.sha256
    }
    |> Inspect.Map.inspect(opts)
  end
end
