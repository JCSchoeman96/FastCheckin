defmodule FastCheck.Tickets.PdfTicket.Error do
  @moduledoc """
  Safe renderer error contract for PDF ticket generation.

  Errors intentionally carry only fixed operational data. They never include
  scanner payloads, ticket codes, raw exceptions, PDF bytes, tokens, hashes, or
  customer contact data.
  """

  @enforce_keys [:reason, :message]
  defstruct @enforce_keys

  @type reason ::
          :invalid_artifact
          | :missing_scanner_payload
          | :malformed_scanner_payload
          | :unsupported_scanner_payload_format
          | :qr_generation_failed
          | :render_failed
          | :document_build_failed

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t()
        }

  @spec new(reason()) :: t()
  def new(reason) do
    %__MODULE__{
      reason: reason,
      message: message(reason)
    }
  end

  defp message(:invalid_artifact), do: "Ticket PDF could not be generated."
  defp message(:missing_scanner_payload), do: "Ticket PDF could not be generated."
  defp message(:malformed_scanner_payload), do: "Ticket PDF could not be generated."
  defp message(:unsupported_scanner_payload_format), do: "Ticket PDF could not be generated."
  defp message(:qr_generation_failed), do: "Ticket PDF could not be generated."
  defp message(:render_failed), do: "Ticket PDF could not be generated."
  defp message(:document_build_failed), do: "Ticket PDF could not be generated."
end

defimpl Inspect, for: FastCheck.Tickets.PdfTicket.Error do
  def inspect(error, opts) do
    %{
      reason: error.reason,
      message: error.message
    }
    |> Inspect.Map.inspect(opts)
  end
end
