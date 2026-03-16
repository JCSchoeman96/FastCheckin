defmodule FastCheckWeb.Api.V1.PackageController do
  use FastCheckWeb, :controller

  action_fallback FastCheckWeb.FallbackController

  alias FastCheck.CheckIns

  def show(conn, %{"event_id" => event_id_param}) do
    with {:ok, event_id} <- parse_event_id(event_id_param) do
      json(conn, %{data: %{package: CheckIns.latest_package_metadata(event_id)}, error: nil})
    end
  end

  defp parse_event_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_event_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, {"INVALID", "event_id must be a positive integer"}}
    end
  end

  defp parse_event_id(_value), do: {:error, {"INVALID", "event_id must be a positive integer"}}
end
