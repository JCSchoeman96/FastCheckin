defmodule FastCheck.Devices.SessionService do
  @moduledoc """
  Issues and validates revocable native device sessions.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias FastCheck.Devices.{Device, DeviceSession}
  alias FastCheck.Events
  alias FastCheck.Repo
  alias FastCheck.Ticketing

  @token_salt "device_session_token"

  @spec create_session(map()) :: {:ok, map()} | {:error, term()}
  def create_session(attrs) when is_map(attrs) do
    with {:ok, scanner_code} <- fetch_required_string(attrs, "scanner_code"),
         {:ok, credential} <- fetch_required_string(attrs, "credential"),
         {:ok, installation_id} <- fetch_required_string(attrs, "device_installation_id"),
         {:ok, %FastCheck.Ticketing.Event{} = event} <- fetch_event(scanner_code),
         :ok <- verify_credential(event, credential) do
      gate_id = parse_optional_int(attrs["gate_id"])
      operator_name = optional_string(attrs["operator_name"])
      app_version = optional_string(attrs["app_version"])
      device_label = optional_string(attrs["device_label"])
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Multi.new()
      |> Multi.insert_or_update(
        :device,
        device_changeset(installation_id, device_label, app_version, now)
      )
      |> Multi.insert(:session, fn %{device: device} ->
        DeviceSession.changeset(%DeviceSession{}, %{
          device_id: device.id,
          event_id: event.id,
          gate_id: gate_id,
          operator_name: operator_name,
          app_version: app_version,
          last_seen_at: now,
          expires_at: DateTime.add(now, session_ttl_seconds(), :second)
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{device: device, session: session}} ->
          {:ok,
           %{
             token: issue_token(session, device),
             session: Repo.preload(session, [:gate]),
             device: device,
             event: event
           }}

        {:error, _operation, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  def create_session(_attrs), do: {:error, :invalid_payload}

  @spec authenticate_bearer(String.t()) :: {:ok, map()} | {:error, term()}
  def authenticate_bearer(token) when is_binary(token) do
    with {:ok, claims} <-
           Phoenix.Token.verify(FastCheckWeb.Endpoint, @token_salt, token,
             max_age: session_ttl_seconds()
           ),
         session_id when is_integer(session_id) <- claims["session_id"],
         device_id when is_integer(device_id) <- claims["device_id"],
         %DeviceSession{} = session <- Repo.get(DeviceSession, session_id),
         %Device{} = device <- Repo.get(Device, device_id),
         :ok <- validate_session(session, device) do
      {:ok,
       %{
         token_claims: claims,
         device: device,
         session: Repo.preload(session, [:gate, :event])
       }}
    else
      nil -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unauthorized}
    end
  end

  def authenticate_bearer(_token), do: {:error, :unauthorized}

  @spec revoke_session(DeviceSession.t()) :: {:ok, DeviceSession.t()} | {:error, term()}
  def revoke_session(%DeviceSession{} = session) do
    session
    |> DeviceSession.changeset(%{revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  defp fetch_event(scanner_code) do
    case Ticketing.get_event_by_scanner_code(scanner_code) do
      %FastCheck.Events.Event{} = event ->
        case Ticketing.get_event(event.id) do
          %FastCheck.Ticketing.Event{} = ticketing_event -> {:ok, ticketing_event}
          nil -> {:error, {"INVALID", "Unknown scanner code"}}
        end

      %FastCheck.Ticketing.Event{} = event ->
        {:ok, event}

      nil ->
        {:error, {"INVALID", "Unknown scanner code"}}
    end
  end

  defp verify_credential(event, credential) do
    event.id
    |> Events.get_event!()
    |> Events.verify_mobile_access_secret(credential)
    |> case do
      :ok -> :ok
      {:error, :invalid_credential} -> {:error, {"FORBIDDEN", "Invalid credential"}}
      {:error, :missing_secret} -> {:error, {"FORBIDDEN", "Scanner credential not configured"}}
      {:error, :missing_credential} -> {:error, {"UNAUTHORIZED", "Credential is required"}}
      _ -> {:error, {"FORBIDDEN", "Invalid credential"}}
    end
  end

  defp device_changeset(installation_id, label, app_version, now) do
    existing =
      Device
      |> where([device], device.installation_id == ^installation_id)
      |> limit(1)
      |> Repo.one() || %Device{}

    Device.changeset(existing, %{
      installation_id: installation_id,
      label: label,
      app_version: app_version,
      status: "active",
      last_seen_at: now
    })
  end

  defp validate_session(session, device) do
    cond do
      not is_nil(session.revoked_at) -> {:error, :forbidden}
      DateTime.compare(session.expires_at, DateTime.utc_now()) == :lt -> {:error, :unauthorized}
      device.status == "revoked" -> {:error, :forbidden}
      true -> :ok
    end
  end

  defp issue_token(session, device) do
    Phoenix.Token.sign(FastCheckWeb.Endpoint, @token_salt, %{
      "session_id" => session.id,
      "device_id" => device.id,
      "event_id" => session.event_id,
      "gate_id" => session.gate_id
    })
  end

  defp fetch_required_string(attrs, key) do
    attrs
    |> Map.get(key)
    |> optional_string()
    |> case do
      nil -> {:error, {"INVALID", "#{key} is required"}}
      value -> {:ok, value}
    end
  end

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(_value), do: nil

  defp parse_optional_int(value) when is_integer(value) and value > 0, do: value

  defp parse_optional_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp parse_optional_int(_value), do: nil

  defp session_ttl_seconds do
    Application.get_env(:fastcheck, :device_session_ttl_seconds, 86_400)
  end
end
