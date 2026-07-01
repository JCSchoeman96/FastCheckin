defmodule FastCheck.Tickets.PdfTicket.SimplePdf do
  @moduledoc """
  Minimal deterministic PDF writer for customer-facing tickets.

  The renderer is request-local and in-memory. It does not call the database,
  shell out, write files, fetch external assets, or rely on browser rendering.
  """

  alias FastCheck.Tickets.Artifact
  alias FastCheck.Tickets.PdfTicket.QrCode

  @page_width 595
  @page_height 842
  @quiet_zone_modules 4
  @qr_printed_width_pt 142
  @qr_x 226
  @qr_y 390
  @font_name "F1"

  @spec render(Artifact.t(), QrCode.t()) :: {:ok, binary()} | {:error, :render_failed}
  def render(%Artifact{} = artifact, %QrCode{} = qr_code) do
    with :ok <- validate_qr_code(qr_code),
         {:ok, content_stream} <- content_stream(artifact, qr_code),
         {:ok, pdf} <- build_pdf(content_stream) do
      {:ok, pdf}
    else
      _other -> {:error, :render_failed}
    end
  rescue
    _error -> {:error, :render_failed}
  end

  def render(_artifact, _qr_code), do: {:error, :render_failed}

  defp validate_qr_code(%QrCode{
         format: :matrix,
         size: size,
         modules: modules,
         dark_module_count: count
       })
       when is_integer(size) and size > 0 and is_list(modules) and is_integer(count) and count > 0 do
    if length(modules) == size and Enum.all?(modules, &(length(&1) == size)) do
      :ok
    else
      {:error, :invalid_qr}
    end
  end

  defp validate_qr_code(_qr_code), do: {:error, :invalid_qr}

  defp content_stream(artifact, qr_code) do
    lines =
      [
        {"FastCheck / Voelgoed Ticket", 24, 70, 782},
        {display_text(artifact.event_name), 16, 70, 742},
        {format_labeled("Date", format_date(artifact.event_date)), 11, 70, 712},
        {format_labeled("Time", format_time(artifact.event_time)), 11, 70, 692},
        {format_labeled("Location", artifact.event_location), 11, 70, 672},
        {format_labeled("Entrance", artifact.entrance_name), 11, 70, 652},
        {format_labeled("Attendee", artifact.attendee_name), 11, 70, 622},
        {format_labeled("Ticket", artifact.ticket_type), 11, 70, 602},
        {"Scan this QR code at the entrance.", 11, 70, 362},
        {fallback_code_text(artifact.scanner_payload), 13, 70, 332},
        {display_text(artifact.support_message), 10, 70, 302},
        {format_labeled("Issued", format_datetime(artifact.issued_at)), 9, 70, 272},
        {format_labeled("Link expires", format_datetime(artifact.delivery_expires_at)), 9, 70,
         254}
      ]
      |> Enum.reject(fn {text, _size, _x, _y} -> is_nil(text) or text == "" end)
      |> Enum.map(fn {text, size, x, y} -> text_operator(text, size, x, y) end)

    qr_ops = qr_operations(qr_code)

    content =
      [
        "% FastCheck PDF ticket\n",
        "% FastCheck QR matrix modules=#{qr_code.size} dark=#{qr_code.dark_module_count} quiet_zone=#{@quiet_zone_modules} printed_width_pt=#{@qr_printed_width_pt}\n",
        "1 1 1 rg\n",
        "#{@qr_x} #{@qr_y} #{@qr_printed_width_pt} #{@qr_printed_width_pt} re f\n",
        "0 0 0 rg\n",
        qr_ops,
        lines,
        "0 0 0 rg\n"
      ]
      |> IO.iodata_to_binary()

    {:ok, content}
  end

  defp qr_operations(%QrCode{modules: modules, size: size}) do
    total_modules = size + @quiet_zone_modules * 2
    module_width = @qr_printed_width_pt / total_modules
    y_top = @qr_y + @qr_printed_width_pt

    modules
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, row_index} ->
      row
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {1, col_index} ->
          x = @qr_x + (col_index + @quiet_zone_modules) * module_width
          y = y_top - (row_index + @quiet_zone_modules + 1) * module_width

          [
            :erlang.float_to_binary(x, decimals: 3),
            " ",
            :erlang.float_to_binary(y, decimals: 3),
            " ",
            :erlang.float_to_binary(module_width, decimals: 3),
            " ",
            :erlang.float_to_binary(module_width, decimals: 3),
            " re f\n"
          ]

        {_other, _col_index} ->
          []
      end)
    end)
  end

  defp text_operator(text, size, x, y) do
    escaped = escape_pdf_text(text)

    [
      "BT /",
      @font_name,
      " ",
      Integer.to_string(size),
      " Tf ",
      Integer.to_string(x),
      " ",
      Integer.to_string(y),
      " Td (",
      escaped,
      ") Tj ET\n"
    ]
  end

  defp fallback_code_text(scanner_payload) when is_binary(scanner_payload) do
    "Ticket code: " <> scanner_payload
  end

  defp display_text(nil), do: nil

  defp display_text(value) when is_binary(value) do
    value
    |> String.replace(~r/[\n\r\t]/, " ")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(120)
  end

  defp display_text(_value), do: nil

  defp format_labeled(_label, nil), do: nil
  defp format_labeled(_label, ""), do: nil
  defp format_labeled(label, value), do: "#{label}: #{display_text(value)}"

  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%b %d, %Y")
  defp format_date(_value), do: nil

  defp format_time(%Time{} = time), do: Calendar.strftime(time, "%H:%M")
  defp format_time(_value), do: nil

  defp format_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_datetime(_value), do: nil

  defp truncate(value, max_length) do
    if String.length(value) > max_length do
      String.slice(value, 0, max_length)
    else
      value
    end
  end

  defp escape_pdf_text(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, " ")
  end

  defp build_pdf(content_stream) do
    stream_length = byte_size(content_stream)

    objects = [
      "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
      "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
      "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{@page_width} #{@page_height}] /Resources << /Font << /#{@font_name} 4 0 R >> >> /Contents 5 0 R >>\nendobj\n",
      "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
      [
        "5 0 obj\n<< /Length ",
        Integer.to_string(stream_length),
        " >>\nstream\n",
        content_stream,
        "\nendstream\nendobj\n"
      ]
      |> IO.iodata_to_binary()
    ]

    header = "%PDF-1.4\n"
    {body, offsets} = objects_with_offsets(objects, byte_size(header))
    xref_offset = byte_size(header) + byte_size(body)
    xref = xref_table(offsets)

    pdf =
      [
        header,
        body,
        xref,
        "trailer\n<< /Size ",
        Integer.to_string(length(objects) + 1),
        " /Root 1 0 R >>\nstartxref\n",
        Integer.to_string(xref_offset),
        "\n%%EOF\n"
      ]
      |> IO.iodata_to_binary()

    {:ok, pdf}
  end

  defp objects_with_offsets(objects, initial_offset) do
    {iodata, offsets, _offset} =
      Enum.reduce(objects, {[], [], initial_offset}, fn object, {parts, offsets, offset} ->
        {[parts, object], [offset | offsets], offset + byte_size(object)}
      end)

    {IO.iodata_to_binary(iodata), Enum.reverse(offsets)}
  end

  defp xref_table(offsets) do
    entries =
      offsets
      |> Enum.map(fn offset ->
        offset
        |> Integer.to_string()
        |> String.pad_leading(10, "0")
        |> Kernel.<>(" 00000 n \n")
      end)

    [
      "xref\n0 ",
      Integer.to_string(length(offsets) + 1),
      "\n0000000000 65535 f \n",
      entries
    ]
  end
end
