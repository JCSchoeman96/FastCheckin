defmodule FastCheck.RuntimeConfiguration do
  @moduledoc """
  Small pure helpers for fail-closed production runtime configuration.
  """

  @strict_true ["1", "true", "yes", "on"]
  @strict_false ["0", "false", "no", "off"]

  @dashboard_username_default "admin"
  @dashboard_password_default "fastcheck"
  @dashboard_password_min_bytes 16

  @dashboard_event_id_pattern ~r/^[0-9]+$/

  @type dashboard_credentials_error ::
          :missing_username
          | :blank_username
          | :missing_password
          | :blank_password
          | :development_fallback_password
          | :password_too_short

  @spec dashboard_credentials(atom(), term(), term()) ::
          {:ok, %{username: String.t(), password: String.t()}}
          | {:error, dashboard_credentials_error()}
  def dashboard_credentials(environment, username, password) do
    username = trim_value(username)
    password = trim_value(password)

    if environment == :prod do
      validate_production_dashboard_credentials(username, password)
    else
      {:ok,
       %{
         username: default_dashboard_value(username, @dashboard_username_default),
         password: default_dashboard_value(password, @dashboard_password_default)
       }}
    end
  end

  @spec dashboard_event_ids(term()) ::
          {:ok, [pos_integer()]} | {:error, :invalid_dashboard_event_ids}
  def dashboard_event_ids(raw_value) when is_binary(raw_value) do
    case String.trim(raw_value) do
      "" ->
        {:ok, []}

      value ->
        value
        |> String.split(",", trim: false)
        |> Enum.reduce_while({:ok, []}, &parse_dashboard_event_id/2)
        |> case do
          {:ok, ids} -> {:ok, ids |> Enum.uniq() |> Enum.sort()}
          {:error, :invalid_dashboard_event_ids} = error -> error
        end
    end
  end

  def dashboard_event_ids(nil), do: {:ok, []}

  def dashboard_event_ids(_raw_value), do: {:error, :invalid_dashboard_event_ids}

  @spec dashboard_event_creation_enabled(term()) ::
          {:ok, boolean()} | {:error, :invalid_dashboard_event_creation_enabled}
  def dashboard_event_creation_enabled(nil), do: {:ok, false}

  def dashboard_event_creation_enabled(raw_value) when is_binary(raw_value) do
    case String.trim(raw_value) do
      "" ->
        {:ok, false}

      value ->
        case strict_boolean(value) do
          {:ok, enabled} -> {:ok, enabled}
          :error -> {:error, :invalid_dashboard_event_creation_enabled}
        end
    end
  end

  def dashboard_event_creation_enabled(_raw_value),
    do: {:error, :invalid_dashboard_event_creation_enabled}

  @spec operations_global_monitoring_usernames(term(), term()) ::
          {:ok, [String.t()]}
          | {:error, :invalid_operations_global_monitoring_usernames | :wildcard_not_allowed}
  def operations_global_monitoring_usernames(raw_value, dashboard_username) do
    bootstrap_username = trim_value(dashboard_username)

    cond do
      blank?(raw_value) ->
        case bootstrap_username do
          username when is_binary(username) and username != "" -> {:ok, [username]}
          _ -> {:error, :invalid_operations_global_monitoring_usernames}
        end

      not is_binary(raw_value) ->
        {:error, :invalid_operations_global_monitoring_usernames}

      true ->
        usernames =
          raw_value
          |> String.split(",", trim: false)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        cond do
          Enum.any?(usernames, &String.contains?(&1, "*")) ->
            {:error, :wildcard_not_allowed}

          usernames == [] ->
            {:error, :invalid_operations_global_monitoring_usernames}

          true ->
            {:ok, usernames}
        end
    end
  end

  @spec whatsapp_sandbox_mode(atom(), boolean(), term()) ::
          {:ok, boolean()} | {:error, :missing | :invalid}
  def whatsapp_sandbox_mode(environment, whatsapp_enabled, raw_value) do
    cond do
      environment == :prod and whatsapp_enabled and blank?(raw_value) ->
        {:error, :missing}

      blank?(raw_value) ->
        {:ok, true}

      true ->
        case strict_boolean(raw_value) do
          {:ok, value} ->
            {:ok, value}

          :error ->
            if environment == :prod and whatsapp_enabled,
              do: {:error, :invalid},
              else: {:ok, false}
        end
    end
  end

  defp strict_boolean(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      value when value in @strict_true -> {:ok, true}
      value when value in @strict_false -> {:ok, false}
      _ -> :error
    end
  end

  defp strict_boolean(_value), do: :error

  defp validate_production_dashboard_credentials(username, password) do
    with :ok <- validate_dashboard_username(username),
         :ok <- validate_dashboard_password(password) do
      {:ok, %{username: username, password: password}}
    end
  end

  defp validate_dashboard_username(nil), do: {:error, :missing_username}
  defp validate_dashboard_username(""), do: {:error, :blank_username}
  defp validate_dashboard_username(_username), do: :ok

  defp validate_dashboard_password(nil), do: {:error, :missing_password}
  defp validate_dashboard_password(""), do: {:error, :blank_password}

  defp validate_dashboard_password(@dashboard_password_default),
    do: {:error, :development_fallback_password}

  defp validate_dashboard_password(password)
       when byte_size(password) < @dashboard_password_min_bytes,
       do: {:error, :password_too_short}

  defp validate_dashboard_password(_password), do: :ok

  defp parse_dashboard_event_id(value, {:ok, ids}) do
    value = String.trim(value)

    if Regex.match?(@dashboard_event_id_pattern, value) do
      case Integer.parse(value) do
        {id, ""} when id > 0 -> {:cont, {:ok, [id | ids]}}
        _ -> {:halt, {:error, :invalid_dashboard_event_ids}}
      end
    else
      {:halt, {:error, :invalid_dashboard_event_ids}}
    end
  end

  defp trim_value(nil), do: nil
  defp trim_value(value) when is_binary(value), do: String.trim(value)
  defp trim_value(_value), do: nil

  defp default_dashboard_value(value, default) when value in [nil, ""], do: default
  defp default_dashboard_value(value, _default), do: value

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
