defmodule FastCheck.Workers.CheckoutExpiryWorker do
  @moduledoc """
  Oban worker that expires one Sales checkout session.

  Delegates to `FastCheck.Sales.CheckoutExpiry`; does not mutate inventory,
  payment, ticket, attendee, or scanner state directly.
  """

  use Oban.Worker,
    queue: :sales_maintenance,
    max_attempts: 8,
    unique: [period: 300, fields: [:args], keys: [:checkout_session_id]]

  alias FastCheck.Sales.CheckoutExpiry

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    session_id = normalize_id(Map.get(args, "checkout_session_id"))
    correlation_id = Map.get(args, "correlation_id")

    opts =
      [correlation_id: correlation_id]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case CheckoutExpiry.expire_session(session_id, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        :telemetry.execute(
          [:fastcheck, :sales, :checkout_expiry, :failed],
          %{count: 1},
          %{checkout_session_id: session_id, error_code: reason, correlation_id: correlation_id}
        )

        {:error, reason}
    end
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp normalize_id(id), do: id
end
