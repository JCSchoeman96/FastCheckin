defmodule FastCheck.RuntimeConfiguration do
  @moduledoc """
  Pure validation helpers used by `config/runtime.exs`.

  These helpers keep production fail-closed parsing executable in unit tests
  without starting the application or exposing protected configuration values.
  """

  @strict_true ["1", "true", "yes", "on"]
  @strict_false ["0", "false", "no", "off"]
  @development_dashboard_passwords ["fastcheck"]

  @spec strict_boolean(term()) :: {:ok, boolean()} | :error
  def strict_boolean(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      value when value in @strict_true -> {:ok, true}
      value when value in @strict_false -> {:ok, false}
      _ -> :error
    end
  end

  def strict_boolean(_value), do: :error

  @spec dashboard_credentials(atom(), term(), term()) ::
          {:ok, %{username: String.t(), password: String.t()}} | {:error, atom()}
  def dashboard_credentials(environment, username, password) do
    if environment == :prod do
      with {:ok, username} <- required_value(username, :missing_username),
           {:ok, password} <- required_value(password, :missing_password),
           :ok <- reject_development_password(password),
           :ok <- validate_password_length(password) do
        {:ok, %{username: username, password: password}}
      end
    else
      {:ok,
       %{
         username: optional_value(username, "admin"),
         password: optional_value(password, "fastcheck")
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

  defp required_value(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_value(_value, error), do: {:error, error}

  defp optional_value(value, fallback) do
    case required_value(value, :blank) do
      {:ok, value} -> value
      {:error, :blank} -> fallback
    end
  end

  defp reject_development_password(password) do
    if String.downcase(password) in @development_dashboard_passwords,
      do: {:error, :development_fallback_password},
      else: :ok
  end

  defp validate_password_length(password) do
    if byte_size(password) >= 16, do: :ok, else: {:error, :password_too_short}
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
