defmodule FastCheckWeb.ScannerSessionController do
  @moduledoc """
  Handles scanner-only session authentication scoped to a single event.
  """

  use FastCheckWeb, :controller

  import Phoenix.Component, only: [to_form: 2]

  alias FastCheck.Events
  alias FastCheck.Events.Event

  @scanner_authenticated_key :scanner_authenticated
  @scanner_event_id_key :scanner_event_id
  @scanner_event_name_key :scanner_event_name
  @scanner_operator_name_key :scanner_operator_name

  def new(conn, params) do
    render(conn, :new,
      form: scanner_login_form(),
      redirect_to: normalize_redirect_to(params["redirect_to"]),
      error_message: nil
    )
  end

  def create(conn, %{"scanner_session" => session_params} = params) do
    with {:ok, event_id} <- extract_event_id(session_params),
         :ok <- ensure_login_event_lock(conn, event_id),
         {:ok, credential} <- extract_credential(session_params),
         {:ok, operator_name} <- extract_operator_name(session_params),
         {:ok, %Event{} = event} <- fetch_event(event_id),
         :ok <- ensure_event_scannable(event),
         :ok <- verify_credential(event, credential) do
      redirect_to = normalize_scanner_redirect_to(params["redirect_to"], event_id)

      conn
      |> put_session(@scanner_authenticated_key, true)
      |> put_session(@scanner_event_id_key, event_id)
      |> put_session(@scanner_event_name_key, event.name || "Event #{event_id}")
      |> put_session(@scanner_operator_name_key, operator_name)
      |> redirect(to: redirect_to)
    else
      {:error, status, message, :preserve_session} ->
        conn
        |> put_status(status)
        |> render(:new,
          form: scanner_login_form(sticky_form_params(session_params)),
          redirect_to: normalize_redirect_to(params["redirect_to"]),
          error_message: message
        )

      {:error, status, message} ->
        conn
        |> clear_scanner_session()
        |> put_status(status)
        |> render(:new,
          form: scanner_login_form(sticky_form_params(session_params)),
          redirect_to: normalize_redirect_to(params["redirect_to"]),
          error_message: message
        )
    end
  end

  def create(conn, _params) do
    conn
    |> clear_scanner_session()
    |> put_status(:bad_request)
    |> render(:new,
      form: scanner_login_form(),
      redirect_to: nil,
      error_message: "Invalid scanner login payload"
    )
  end

  def delete(conn, _params) do
    conn
    |> clear_scanner_session()
    |> redirect(to: ~p"/scanner/login")
  end

  def update_operator(conn, %{"event_id" => event_id_param} = params) do
    case parse_event_id_value(event_id_param) do
      {:ok, event_id} ->
        with :ok <- ensure_scanner_event_lock(conn, event_id),
             {:ok, operator_name} <- extract_operator_name(params) do
          redirect_to = normalize_scanner_redirect_to(params["redirect_to"], event_id)

          conn
          |> put_session(@scanner_operator_name_key, operator_name)
          |> put_flash(:info, "Operator updated to #{operator_name}")
          |> redirect(to: redirect_to)
        else
          {:error, :bad_request, message} ->
            conn
            |> put_flash(:error, message)
            |> redirect(to: normalize_scanner_redirect_to(params["redirect_to"], event_id))

          {:error, :forbidden, message} ->
            conn
            |> clear_scanner_session()
            |> put_flash(:error, message)
            |> redirect(to: ~p"/scanner/login")
        end

      {:error, _status, message} ->
        conn
        |> clear_scanner_session()
        |> put_flash(:error, message)
        |> redirect(to: ~p"/scanner/login")
    end
  end

  def update_operator(conn, _params) do
    conn
    |> clear_scanner_session()
    |> put_flash(:error, "Invalid operator update payload")
    |> redirect(to: ~p"/scanner/login")
  end

  defp scanner_login_form(
         params \\ %{"event_id" => "", "credential" => "", "operator_name" => ""}
       ) do
    to_form(params, as: "scanner_session")
  end

  defp sticky_form_params(params) do
    %{
      "event_id" => Map.get(params, "event_id", ""),
      "credential" => "",
      "operator_name" => Map.get(params, "operator_name", "")
    }
  end

  defp extract_event_id(%{"event_id" => value}), do: parse_event_id_value(value)

  defp extract_event_id(_params), do: {:error, :bad_request, "Event ID is required"}

  defp extract_credential(%{"credential" => credential}) when is_binary(credential) do
    if String.trim(credential) == "" do
      {:error, :unauthorized, "Event password is required"}
    else
      {:ok, String.trim(credential)}
    end
  end

  defp extract_credential(%{"credential" => _value}),
    do: {:error, :unauthorized, "Event password is required"}

  defp extract_credential(_params), do: {:error, :unauthorized, "Event password is required"}

  defp extract_operator_name(%{"operator_name" => operator_name}) when is_binary(operator_name) do
    trimmed = String.trim(operator_name)

    if trimmed == "" do
      {:error, :bad_request, "Operator name is required"}
    else
      {:ok, trimmed}
    end
  end

  defp extract_operator_name(%{"operator_name" => _value}),
    do: {:error, :bad_request, "Operator name is required"}

  defp extract_operator_name(_params), do: {:error, :bad_request, "Operator name is required"}

  defp ensure_login_event_lock(conn, target_event_id) do
    if get_session(conn, @scanner_authenticated_key) == true do
      case parse_event_id_value(get_session(conn, @scanner_event_id_key)) do
        {:ok, locked_event_id} when locked_event_id != target_event_id ->
          {:error, :forbidden,
           "Scanner is locked to Event ID #{locked_event_id}. Log out before switching events.",
           :preserve_session}

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp ensure_scanner_event_lock(conn, event_id) do
    with true <- get_session(conn, @scanner_authenticated_key) == true,
         {:ok, session_event_id} <- parse_event_id_value(get_session(conn, @scanner_event_id_key)),
         true <- session_event_id == event_id do
      :ok
    else
      _ ->
        {:error, :forbidden, "Scanner session mismatch. Please sign in again."}
    end
  end

  defp fetch_event(event_id) do
    {:ok, Events.get_event!(event_id)}
  rescue
    Ecto.NoResultsError ->
      {:error, :not_found, "Event with ID #{event_id} does not exist"}
  end

  defp ensure_event_scannable(%Event{} = event) do
    case Events.can_check_in?(event) do
      {:ok, _state} ->
        :ok

      {:error, {:event_archived, message}} ->
        {:error, :forbidden, message}

      {:error, {_reason, message}} ->
        {:error, :forbidden, message || "Scanning is disabled for this event"}
    end
  end

  defp verify_credential(%Event{} = event, credential) do
    case Events.verify_mobile_access_secret(event, credential) do
      :ok ->
        :ok

      {:error, :invalid_credential} ->
        {:error, :forbidden, "Event password is invalid"}

      {:error, :missing_secret} ->
        {:error, :forbidden, "Event scanner password is not configured"}

      {:error, :missing_credential} ->
        {:error, :unauthorized, "Event password is required"}

      _other ->
        {:error, :forbidden, "Event password is invalid"}
    end
  end

  defp clear_scanner_session(conn) do
    conn
    |> delete_session(@scanner_authenticated_key)
    |> delete_session(@scanner_event_id_key)
    |> delete_session(@scanner_event_name_key)
    |> delete_session(@scanner_operator_name_key)
  end

  defp normalize_scanner_redirect_to(redirect_to, event_id) do
    fallback = ~p"/scanner/#{event_id}?tab=camera"

    redirect_to
    |> normalize_redirect_to()
    |> case do
      nil ->
        fallback

      safe_path ->
        if valid_scanner_redirect_for_event?(safe_path, event_id), do: safe_path, else: fallback
    end
  end

  defp valid_scanner_redirect_for_event?(path, event_id) when is_binary(path) do
    base_prefix = "/scanner/#{event_id}"
    path == base_prefix or String.starts_with?(path, base_prefix <> "?")
  end

  defp valid_scanner_redirect_for_event?(_path, _event_id), do: false

  defp parse_event_id_value(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_event_id_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {event_id, ""} when event_id > 0 -> {:ok, event_id}
      _ -> {:error, :bad_request, "Event ID must be a positive integer"}
    end
  end

  defp parse_event_id_value(_value),
    do: {:error, :bad_request, "Event ID must be a positive integer"}

  defp normalize_redirect_to(nil), do: nil
  defp normalize_redirect_to(""), do: nil

  defp normalize_redirect_to(redirect_to) when is_binary(redirect_to) do
    redirect_to
    |> decode_redirect_param()
    |> ensure_safe_path()
  end

  defp normalize_redirect_to(_), do: nil

  defp decode_redirect_param(value) do
    decoded = URI.decode_www_form(value)

    if decoded == value do
      decoded
    else
      URI.decode_www_form(decoded)
    end
  end

  defp ensure_safe_path("/" <> _ = path) do
    if String.starts_with?(path, "//"), do: nil, else: path
  end

  defp ensure_safe_path(_), do: nil
end
