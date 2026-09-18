defmodule FastCheck.RuntimeConfiguration do
  @moduledoc """
  Small pure helpers for fail-closed production runtime configuration.
  """

  @strict_true ["1", "true", "yes", "on"]
  @strict_false ["0", "false", "no", "off"]

  @dashboard_username_default "admin"
  @dashboard_password_default "fastcheck"
  @dashboard_password_min_bytes 16

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

  defp trim_value(nil), do: nil
  defp trim_value(value) when is_binary(value), do: String.trim(value)
  defp trim_value(_value), do: nil

  defp default_dashboard_value(value, default) when value in [nil, ""], do: default
  defp default_dashboard_value(value, _default), do: value

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
