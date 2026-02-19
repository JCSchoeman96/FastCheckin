defmodule FastCheckWeb.FallbackController do
  @moduledoc """
  Translates controller action results into valid HTTP responses.

  Centralizes error handling for API endpoints, converting error tuples
  into standardized JSON responses with appropriate HTTP status codes.
  """

  use FastCheckWeb, :controller
  require Logger

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      data: nil,
      error: %{
        code: "VALIDATION_ERROR",
        message: "Validation failed",
        details: translate_errors(changeset)
      }
    })
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{
      data: nil,
      error: %{
        code: "NOT_FOUND",
        message: "Resource not found"
      }
    })
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{
      data: nil,
      error: %{
        code: "UNAUTHORIZED",
        message: "Authentication required"
      }
    })
  end

  def call(conn, {:error, :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      data: nil,
      error: %{
        code: "FORBIDDEN",
        message: "Access denied"
      }
    })
  end

  def call(conn, {:error, code, message}) when is_binary(code) and is_binary(message) do
    status = error_code_to_status(code)

    conn
    |> put_status(status)
    |> json(%{
      data: nil,
      error: %{
        code: code,
        message: message
      }
    })
  end

  def call(conn, {:error, message}) when is_binary(message) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      data: nil,
      error: %{
        code: "BAD_REQUEST",
        message: message
      }
    })
  end

  def call(conn, {:error, reason}) do
    Logger.error("Unhandled error in FallbackController: #{inspect(reason)}")

    conn
    |> put_status(:internal_server_error)
    |> json(%{
      data: nil,
      error: %{
        code: "INTERNAL_ERROR",
        message: "An unexpected error occurred"
      }
    })
  end

  # Translate Ecto changeset errors into a readable format
  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  # Map common error codes to HTTP status codes
  defp error_code_to_status("INVALID"), do: :bad_request
  defp error_code_to_status("INVALID_TICKET"), do: :bad_request
  defp error_code_to_status("DUPLICATE"), do: :conflict
  defp error_code_to_status("DUPLICATE_TODAY"), do: :conflict
  defp error_code_to_status("ALREADY_INSIDE"), do: :conflict
  defp error_code_to_status("LIMIT_EXCEEDED"), do: :forbidden
  defp error_code_to_status("NOT_YET_VALID"), do: :forbidden
  defp error_code_to_status("EXPIRED"), do: :forbidden
  defp error_code_to_status("ARCHIVED_EVENT"), do: :forbidden
  defp error_code_to_status("SCANS_DISABLED"), do: :forbidden
  defp error_code_to_status(_), do: :bad_request
end
