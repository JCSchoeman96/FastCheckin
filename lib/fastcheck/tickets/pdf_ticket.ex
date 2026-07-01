defmodule FastCheck.Tickets.PdfTicket do
  @moduledoc """
  Renderer-only PDF ticket generation from an already-resolved ticket artifact.

  This module deliberately does not resolve delivery tokens, query ticket state,
  mutate scanner/payment/revocation state, store PDFs, or deliver files. It only
  renders valid `%FastCheck.Tickets.Artifact{}` values.
  """

  alias FastCheck.Tickets.Artifact
  alias FastCheck.Tickets.ArtifactError
  alias FastCheck.Tickets.PdfTicket.Document
  alias FastCheck.Tickets.PdfTicket.Error
  alias FastCheck.Tickets.PdfTicket.QrCode
  alias FastCheck.Tickets.PdfTicket.SimplePdf

  @spec generate(term()) ::
          {:ok, Document.t()}
          | {:error, ArtifactError.t()}
          | {:error, Error.t()}
          | {:error, :invalid_artifact}
  def generate({:ok, %Artifact{} = artifact}), do: generate(artifact)
  def generate({:error, %ArtifactError{} = error}), do: {:error, error}
  def generate(%ArtifactError{} = error), do: {:error, error}

  def generate(%Artifact{} = artifact) do
    with :ok <- validate_artifact(artifact),
         {:ok, qr_code} <- build_qr_code(artifact.scanner_payload),
         {:ok, pdf_binary} <- render_pdf(artifact, qr_code),
         {:ok, document} <- build_document(pdf_binary) do
      {:ok, document}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} when is_atom(reason) -> {:error, Error.new(reason)}
    end
  rescue
    _error -> {:error, Error.new(:render_failed)}
  end

  def generate(_input), do: {:error, :invalid_artifact}

  defp validate_artifact(%Artifact{state: state}) when state != :valid do
    {:error, :invalid_artifact}
  end

  defp validate_artifact(%Artifact{scanner_payload: payload}) when not is_binary(payload) do
    {:error, :missing_scanner_payload}
  end

  defp validate_artifact(%Artifact{scanner_payload: payload, scanner_payload_format: format}) do
    cond do
      payload == "" or String.trim(payload) == "" ->
        {:error, :missing_scanner_payload}

      payload != String.trim(payload) ->
        {:error, :malformed_scanner_payload}

      format != :plain_ticket_code ->
        {:error, :unsupported_scanner_payload_format}

      true ->
        :ok
    end
  end

  defp validate_artifact(_artifact), do: :ok

  defp build_qr_code(payload) do
    case QrCode.from_payload(payload) do
      {:ok, qr_code} -> {:ok, qr_code}
      {:error, :blank_payload} -> {:error, :missing_scanner_payload}
      {:error, :malformed_payload} -> {:error, :malformed_scanner_payload}
      {:error, _reason} -> {:error, :qr_generation_failed}
    end
  end

  defp render_pdf(artifact, qr_code) do
    case SimplePdf.render(artifact, qr_code) do
      {:ok, pdf_binary} -> {:ok, pdf_binary}
      {:error, _reason} -> {:error, :render_failed}
    end
  end

  defp build_document(pdf_binary) do
    case Document.new(pdf_binary) do
      {:ok, document} -> {:ok, document}
      {:error, _reason} -> {:error, :document_build_failed}
    end
  end
end
