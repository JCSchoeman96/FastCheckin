defmodule FastCheckWeb.Plugs.DeviceScope do
  @moduledoc """
  Ensures device-scoped API requests include authenticated device and session
  context before reaching controllers.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %Plug.Conn{assigns: %{current_device: _device, current_device_session: _session}} = conn,
        _opts
      ),
      do: conn

  def call(conn, _opts) do
    conn
    |> put_status(:unauthorized)
    |> json(%{data: nil, error: %{code: "UNAUTHORIZED", message: "Device scope missing"}})
    |> halt()
  end
end
