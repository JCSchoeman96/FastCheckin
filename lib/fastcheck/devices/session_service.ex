defmodule FastCheck.Devices.SessionService do
  @moduledoc """
  Issues and validates revocable native device sessions.
  """

  import Ecto.Query, warn: false
  alias FastCheck.Devices.{Device, DeviceSession}
  alias FastCheck.Events
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  @token_salt "device_session_token"

  @spec create_session(map()) :: {:ok, map()} | {:error, term()}
  def create_session(attrs) when is_map(attrs) do
    with {:ok, scanner_code} <- fetch_required_string(attrs, "scanner_code"),
         {:ok, credential} <- fetch_required_string(attrs, "credential"),
         {:ok, installation_id} <- fetch_required_string(attrs, "device_installation_id"),
         {:ok, %Event{} = event} <- fetch_event(scanner_code),
         :ok <- verify_credential(event, credential) do
      gate_id = parse_optional_int(attrs["gate_id"])
      operator_name = optional_string(attrs["operator_name"])
      app_version = optional_string(attrs["app_version"])
      device_label = optional_string(attrs["device_label"])
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.transaction(fn ->
        with {:ok, device} <-
               installation_id
               |> device_changeset(device_label, app_version, now)
               |> Repo.insert_or_update(),
             {:ok, session} <-
               %DeviceSession{}
               |> DeviceSession.changeset(%{
                 device_id: device.id,
                 event_id: event.id,
                 gate_id: gate_id,
                 operator_name: operator_name,
                 app_version: app_version,
                 last_seen_at: now,
                 expires_at: DateTime.add(now, session_ttl_seconds(), :second)
               })
               |> Repo.insert() do
          %{
            token: issue_token(session, device),
            session: Repo.preload(session, [:gate]),
            device: device,
            event: event
          }
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, session_data} ->
          {:ok, session_data}

        {:error, reason} ->
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
    case Events.get_event_by_scanner_login_code(scanner_code) do
      %Event{} = event ->
        {:ok, event}

      nil ->
        {:error, {"INVALID", "Unknown scanner code"}}
    end
  end

  defp verify_credential(%Event{} = event, credential) do
    case Events.verify_mobile_access_secret(event, credential) do
      :ok -> :ok
      {:error, :invalid_credential} -> {:error, {"FORBIDDEN", "Invalid credential"}}
      {:error, :missing_secret} -> {:error, {"FORBIDDEN", "Scanner credential not configured"}}
      {:error, :missing_credential} -> {:error, {"UNAUTHORIZED", "Credential is required"}}
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
