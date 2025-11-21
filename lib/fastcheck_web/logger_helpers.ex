defmodule FastCheckWeb.LoggerHelpers do
  @moduledoc """
  Helper functions for setting Logger metadata in LiveViews and controllers.

  ## Usage in LiveView

      defmodule MyApp.EventLive do
        use MyAppWeb, :live_view
        import FastCheckWeb.LoggerHelpers

        def mount(%{"event_id" => event_id}, _session, socket) do
          set_event_metadata(event_id)
          {:ok, assign(socket, :current_event_id, event_id)}
        end
      end

  ## Usage in Controller

      defmodule MyApp.EventController do
        use MyAppWeb, :controller
        import FastCheckWeb.LoggerHelpers

        def show(conn, %{"id" => event_id}) do
          set_event_metadata(event_id)
          # ... rest of controller action
        end
      end

  ## Manual Metadata

  You can also set metadata manually:

      Logger.metadata(event_id: 123, custom_field: "value")
  """

  require Logger

  @doc """
  Sets event_id in Logger metadata.

  Accepts either an integer or string event_id and converts it appropriately.
  """
  def set_event_metadata(event_id) when is_binary(event_id) do
    case Integer.parse(event_id) do
      {int, _} -> Logger.metadata(event_id: int)
      :error -> :ok
    end
  end

  def set_event_metadata(event_id) when is_integer(event_id) do
    Logger.metadata(event_id: event_id)
  end

  def set_event_metadata(_), do: :ok

  @doc """
  Sets user_id in Logger metadata.
  """
  def set_user_metadata(user_id) when is_integer(user_id) do
    Logger.metadata(user_id: user_id)
  end

  def set_user_metadata(_), do: :ok

  @doc """
  Sets device_id in Logger metadata (useful for mobile API).
  """
  def set_device_metadata(device_id) when is_binary(device_id) do
    Logger.metadata(device_id: device_id)
  end

  def set_device_metadata(_), do: :ok

  @doc """
  Sets custom metadata fields in bulk.

  ## Example

      set_metadata(event_id: 123, user_id: 456, custom: "value")
  """
  def set_metadata(fields) when is_list(fields) do
    Logger.metadata(fields)
  end
end
