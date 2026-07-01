defmodule FastCheck.Tickets.PdfTicketTest do
  use ExUnit.Case, async: true

  alias FastCheck.Tickets.Artifact
  alias FastCheck.Tickets.ArtifactError
  alias FastCheck.Tickets.PdfTicket
  alias FastCheck.Tickets.PdfTicket.Document
  alias FastCheck.Tickets.PdfTicket.Error
  alias FastCheck.Tickets.PdfTicket.QrCode
  alias FastCheck.Tickets.PdfTicket.SimplePdf

  @ticket_code "FC-25955-1"
  @forbidden_values [
    "delivery_token",
    "delivery_token_hash",
    "qr_token_hash",
    "paystack-secret-value",
    "access_code_secret",
    "provider_payload_secret",
    "http://internal.fastcheck.local/tickets/1",
    "https://internal.fastcheck.local/tickets/1",
    "buyer@example.test",
    "+27821234567"
  ]

  describe "generate/1" do
    test "valid artifact generates a safe PDF document with QR and fallback ticket code" do
      artifact = valid_artifact()

      assert {:ok, %Document{} = document} = PdfTicket.generate(artifact)

      assert document.content_type == "application/pdf"
      assert document.filename == "fastcheck-ticket.pdf"
      assert document.byte_size == byte_size(document.binary)
      assert document.sha256 == sha256(document.binary)
      assert document.binary =~ "%PDF-"
      assert String.starts_with?(document.binary, "%PDF-")

      assert document.binary =~ "FastCheck / Voelgoed Ticket"
      assert document.binary =~ "Voelgoed Live"
      assert document.binary =~ "Jan 15, 2026"
      assert document.binary =~ "19:30"
      assert document.binary =~ "Main Venue"
      assert document.binary =~ "Main Gate"
      assert document.binary =~ "Ada Lovelace"
      assert document.binary =~ "General Admission"
      assert document.binary =~ "Present this ticket code at the entrance scanner."

      assert document.binary =~ "% FastCheck QR matrix modules="
      assert document.binary =~ "quiet_zone=4"
      assert document.binary =~ "printed_width_pt=142"
      assert document.binary =~ "Ticket code: #{@ticket_code}"
    end

    test "{:ok, artifact} generates a PDF document" do
      assert {:ok, %Document{}} = PdfTicket.generate({:ok, valid_artifact()})
    end

    test "QR generation is deterministic and based on the exact scanner payload" do
      assert {:ok, %QrCode{} = qr} = QrCode.from_payload(@ticket_code)
      assert {:ok, %QrCode{} = same_qr} = QrCode.from_payload(valid_artifact().scanner_payload)
      assert qr.modules == same_qr.modules

      assert {:ok, %QrCode{} = different_qr} = QrCode.from_payload(@ticket_code <> "X")
      refute qr.modules == different_qr.modules
    end

    test "readable fallback ticket code matches QR source exactly" do
      scanner_payload = "FC-Exact-ABC123"
      artifact = valid_artifact(scanner_payload: scanner_payload)

      assert {:ok, %Document{} = document} = PdfTicket.generate(artifact)
      assert document.binary =~ "Ticket code: #{scanner_payload}"
    end

    test "optional customer fields may be absent" do
      artifact =
        valid_artifact(
          attendee_name: nil,
          ticket_type: nil,
          event_date: nil,
          event_time: nil,
          event_location: nil,
          entrance_name: nil,
          issued_at: nil,
          delivery_expires_at: nil
        )

      assert {:ok, %Document{} = document} = PdfTicket.generate(artifact)
      assert document.binary =~ "Ticket code: #{@ticket_code}"
    end

    test "artifact errors return the safe error and do not generate a PDF" do
      error = artifact_error(:ticket_revoked)

      assert {:error, ^error} = PdfTicket.generate({:error, error})
      assert {:error, ^error} = PdfTicket.generate(error)
    end

    test "non-artifact input returns a safe invalid artifact error" do
      assert {:error, :invalid_artifact} = PdfTicket.generate(%{scanner_payload: @ticket_code})
    end

    test "nil scanner payload fails closed" do
      assert {:error, %Error{reason: :missing_scanner_payload} = error} =
               PdfTicket.generate(valid_artifact(scanner_payload: nil))

      refute inspect(error) =~ @ticket_code
    end

    test "blank scanner payload fails closed" do
      assert {:error, %Error{reason: :missing_scanner_payload}} =
               PdfTicket.generate(valid_artifact(scanner_payload: "   "))
    end

    test "leading or trailing scanner payload whitespace fails closed" do
      assert {:error, %Error{reason: :malformed_scanner_payload} = error} =
               PdfTicket.generate(valid_artifact(scanner_payload: " #{@ticket_code}"))

      refute inspect(error) =~ @ticket_code
    end

    test "scanner payload control characters fail closed" do
      for payload <- ["FC-123\n456", "FC-123\t456", "FC-123\r456", "FC-123" <> <<0>>] do
        assert {:error, %Error{reason: :malformed_scanner_payload} = error} =
                 PdfTicket.generate(valid_artifact(scanner_payload: payload))

        refute inspect(error) =~ payload
      end
    end

    test "non-valid artifact state fails closed" do
      assert {:error, %Error{reason: :invalid_artifact}} =
               PdfTicket.generate(valid_artifact(state: :ticket_revoked))
    end

    test "unsupported scanner payload format fails closed" do
      assert {:error, %Error{reason: :unsupported_scanner_payload_format}} =
               PdfTicket.generate(valid_artifact(scanner_payload_format: :delivery_token))
    end

    test "QR generation failure returns safe error without leaking the payload" do
      payload = String.duplicate("A", 3000)

      assert {:error, %Error{reason: :qr_generation_failed} = error} =
               PdfTicket.generate(valid_artifact(scanner_payload: payload))

      refute inspect(error) =~ payload
    end

    test "inspect(document) exposes metadata but not payloads or PDF bytes" do
      assert {:ok, %Document{} = document} = PdfTicket.generate(valid_artifact())

      inspected = inspect(document)

      assert inspected =~ "application/pdf"
      assert inspected =~ "fastcheck-ticket.pdf"
      assert inspected =~ document.sha256
      refute inspected =~ "%PDF-"
      refute inspected =~ document.binary
      refute inspected =~ @ticket_code
      refute_forbidden_values(inspected)
    end

    test "generated PDF excludes seeded internal values and patterns" do
      assert {:ok, %Document{} = document} = PdfTicket.generate(valid_artifact())

      refute_forbidden_values(document.binary)
      refute document.binary =~ ~r/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i
      refute document.binary =~ ~r/\+27\d{9}/
    end
  end

  describe "QrCode.from_payload/1" do
    test "returns deterministic matrix data without retaining the source value" do
      assert {:ok, %QrCode{} = qr} = QrCode.from_payload(@ticket_code)

      assert qr.format == :matrix
      assert is_integer(qr.size)
      assert qr.size > 0
      assert length(qr.modules) == qr.size
      assert Enum.all?(qr.modules, &(length(&1) == qr.size))
      assert qr.dark_module_count > 0
      refute Map.has_key?(Map.from_struct(qr), :source)
      refute inspect(qr) =~ @ticket_code
    end

    test "fails closed for nil, blank, non-binary, whitespace, and control-character payloads" do
      assert {:error, :blank_payload} = QrCode.from_payload(nil)
      assert {:error, :blank_payload} = QrCode.from_payload(" ")
      assert {:error, :malformed_payload} = QrCode.from_payload(123)
      assert {:error, :malformed_payload} = QrCode.from_payload(" #{@ticket_code}")
      assert {:error, :malformed_payload} = QrCode.from_payload("#{@ticket_code} ")
      assert {:error, :malformed_payload} = QrCode.from_payload("FC-123\n456")
      assert {:error, :malformed_payload} = QrCode.from_payload("FC-123\t456")
      assert {:error, :malformed_payload} = QrCode.from_payload("FC-123\r456")
      assert {:error, :malformed_payload} = QrCode.from_payload("FC-123" <> <<0>>)
    end
  end

  describe "SimplePdf.render/2" do
    test "returns safe render failure for malformed QR data" do
      malformed_qr = %QrCode{format: :matrix, size: 0, modules: [], dark_module_count: 0}

      assert {:error, :render_failed} = SimplePdf.render(valid_artifact(), malformed_qr)
    end

    test "escapes PDF text operators and sanitizes control characters" do
      artifact =
        valid_artifact(
          event_name: "Event (VIP) \\ Launch\nNight\t\u0001",
          attendee_name: "Ada (Scanner) \\ Name\r",
          ticket_type: "General \\ (A)",
          support_message: "Line one\nLine two\t\u0002"
        )

      assert {:ok, %Document{} = document} = PdfTicket.generate(artifact)

      assert document.binary =~ "Event \\(VIP\\) \\\\ Launch Night"
      assert document.binary =~ "Ada \\(Scanner\\) \\\\ Name"
      assert document.binary =~ "General \\\\ \\(A\\)"
      assert document.binary =~ "Line one Line two"
      refute document.binary =~ "\u0001"
      refute document.binary =~ "\u0002"
    end

    test "builds valid xref offsets and exact content stream length" do
      assert {:ok, %Document{} = document} = PdfTicket.generate(valid_artifact())

      assert_pdf_xref_offsets(document.binary)
      assert_pdf_stream_lengths(document.binary)
    end
  end

  describe "Document.new/2" do
    test "builds safe metadata for valid PDFs" do
      generated_at = ~U[2026-07-01 10:00:00Z]

      assert {:ok, %Document{} = document} = Document.new("%PDF-1.4\n%%EOF\n", generated_at)

      assert document.generated_at == generated_at
      assert document.content_type == "application/pdf"
      assert document.filename == "fastcheck-ticket.pdf"
      assert document.byte_size == byte_size(document.binary)
      assert document.sha256 == sha256(document.binary)
    end

    test "rejects invalid PDF binaries without raising" do
      assert {:error, :invalid_pdf} = Document.new("not a pdf")
      assert {:error, :invalid_pdf} = Document.new(nil)
    end
  end

  defp valid_artifact(attrs \\ []) do
    defaults = %{
      state: :valid,
      event_name: "Voelgoed Live",
      attendee_name: "Ada Lovelace",
      ticket_type: "General Admission",
      scanner_payload: @ticket_code,
      scanner_payload_format: :plain_ticket_code,
      support_message: "Present this ticket code at the entrance scanner.",
      issued_at: ~U[2026-01-01 10:00:00Z],
      delivery_expires_at: ~U[2026-01-08 10:00:00Z],
      event_date: ~D[2026-01-15],
      event_time: ~T[19:30:00],
      event_location: "Main Venue",
      entrance_name: "Main Gate"
    }

    struct!(Artifact, Map.merge(defaults, Map.new(attrs)))
  end

  defp artifact_error(state) do
    %ArtifactError{
      state: state,
      support_message: "This ticket cannot be rendered.",
      http_status_hint: :ok
    }
  end

  defp sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  defp refute_forbidden_values(value) do
    for forbidden <- @forbidden_values do
      refute value =~ forbidden
    end
  end

  defp assert_pdf_xref_offsets(binary) do
    [_, xref_offset_text] = Regex.run(~r/startxref\s+(\d+)/, binary)
    xref_offset = String.to_integer(xref_offset_text)

    assert binary_part(binary, xref_offset, 4) == "xref"

    [xref_section | _] =
      binary
      |> binary_part(xref_offset, byte_size(binary) - xref_offset)
      |> String.split("trailer", parts: 2)

    xref_section
    |> String.split("\n")
    |> Enum.filter(&Regex.match?(~r/^\d{10} \d{5} [nf]\s*$/, &1))
    |> Enum.reject(&Regex.match?(~r/\sf\s*$/, &1))
    |> Enum.each(fn line ->
      offset = line |> binary_part(0, 10) |> String.to_integer()
      assert binary_part(binary, offset, 3) =~ ~r/\d+\s/
    end)
  end

  defp assert_pdf_stream_lengths(binary) do
    Regex.scan(~r/(\d+) 0 obj\s*<<\s*\/Length (\d+)\s*>>\s*stream\n(.*?)\nendstream/s, binary)
    |> Enum.each(fn [_match, _object_number, length_text, stream] ->
      assert byte_size(stream) == String.to_integer(length_text)
    end)
  end
end
