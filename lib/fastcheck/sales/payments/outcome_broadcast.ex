defmodule FastCheck.Sales.Payments.OutcomeBroadcast do
  @moduledoc """
  Best-effort sanitized PubSub broadcasts for Sales payment outcomes.

  VS-07C emits operational hooks for future admin/dashboard work. Broadcast
  failures must never fail payment outcome handling.
  """

  alias FastCheck.Observability.Correlation
  alias FastCheck.Observability.Redactor
  alias Phoenix.PubSub

  @pubsub FastCheck.PubSub

  @topics %{
    mismatch: "payments:mismatch",
    manual_review: "payments:manual_review",
    unmatched_event: "payments:unmatched_event",
    duplicate_ignored: "payments:duplicate_ignored",
    late_payment_recovered: "payments:late_payment_recovered",
    late_payment_manual_review: "payments:late_payment_manual_review"
  }

  @allowed_keys ~w(
    payment_attempt_id
    payment_event_id
    order_id
    checkout_session_id
    status
    reason_code
    correlation_id
    outcome
  )a

  @spec broadcast(atom(), map()) :: :ok
  def broadcast(kind, metadata) when is_atom(kind) and is_map(metadata) do
    topic = Map.get(@topics, kind)

    if topic do
      payload =
        metadata
        |> Correlation.operational_metadata()
        |> Redactor.safe_metadata()
        |> Map.take(@allowed_keys)
        |> Map.put(:outcome, Atom.to_string(kind))

      try do
        PubSub.broadcast(@pubsub, topic, {:sales_payment_outcome, payload})
      catch
        _, _ -> :ok
      else
        :ok -> :ok
        _ -> :ok
      end
    else
      :ok
    end
  end
end
