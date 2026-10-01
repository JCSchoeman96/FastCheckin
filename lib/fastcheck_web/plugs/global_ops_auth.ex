defmodule FastCheckWeb.Plugs.GlobalOpsAuth do
  @moduledoc """
  Enforces the independent server-owned global operations allowlist.
  """

  import Plug.Conn

  alias FastCheck.Operations.GlobalAccess

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if GlobalAccess.authorized_identity?(conn) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(:forbidden, "Forbidden")
      |> halt()
    end
  end
end
