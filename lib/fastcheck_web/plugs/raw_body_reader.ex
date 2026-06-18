defmodule FastCheckWeb.Plugs.RawBodyReader do
  @moduledoc """
  Plug.Parsers body reader that preserves raw request bytes for Paystack webhooks.

  Only `POST /api/sales/paystack/webhook` stores `conn.private[:raw_body]`. All
  other routes read the body without retaining it.
  """

  alias Plug.Conn

  @webhook_path "/api/sales/paystack/webhook"

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    if store_raw_body?(conn) do
      read_and_store(conn, opts, "")
    else
      Conn.read_body(conn, opts)
    end
  end

  defp store_raw_body?(conn) do
    conn.method == "POST" and conn.request_path == @webhook_path
  end

  defp read_and_store(conn, opts, acc) do
    case Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        raw_body = acc <> normalize_chunk(body)
        conn = Conn.put_private(conn, :raw_body, raw_body)
        {:ok, raw_body, conn}

      {:more, partial, conn} ->
        read_and_store(conn, opts, acc <> normalize_chunk(partial))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_chunk(chunk) when is_binary(chunk), do: chunk
  defp normalize_chunk(_), do: ""
end
