defmodule FastCheckWeb.Plugs.RawBodyReader do
  @moduledoc """
  Plug.Parsers body reader that preserves raw request bytes for provider webhooks.

  Only approved provider webhook POSTs store `conn.private[:raw_body]`. All
  other routes read the body without retaining it.

  Webhook routes perform a single `read_body/2` call so Plug's `length` and
  `read_length` limits remain enforced; partial `{:more, ...}` responses are not
  accumulated here.
  """

  alias Plug.Conn

  @webhook_paths MapSet.new([
                   "/api/sales/paystack/webhook",
                   "/api/v1/webhooks/whatsapp"
                 ])

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    if store_raw_body?(conn) do
      case Conn.read_body(conn, opts) do
        {:ok, body, conn} ->
          conn = Conn.put_private(conn, :raw_body, body)
          {:ok, body, conn}

        {:more, _partial, _conn} = more ->
          more

        {:error, _reason} = error ->
          error
      end
    else
      Conn.read_body(conn, opts)
    end
  end

  defp store_raw_body?(conn) do
    conn.method == "POST" and MapSet.member?(@webhook_paths, conn.request_path)
  end
end
