defmodule FastCheck.Tickets.TicketExchange do
  @moduledoc """
  P1E-C1 internal orchestration for delivery-token → browser-session registry exchange.

  Validates through `ArtifactResolver`, binds generation-aware Redis state via
  `TicketSession`, then re-reads Postgres before success. HTTP cookies and public
  routes are wired in P1E-C2.
  """

  alias Ash
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Tickets.ArtifactError
  alias FastCheck.Tickets.ArtifactResolver
  alias FastCheck.Tickets.DeliveryToken
  alias FastCheck.Tickets.TicketSession

  @type exchange_error ::
          :invalid_token
          | :expired_token
          | :revoked_token
          | :not_ready
          | :not_scannable
          | :session_unavailable
          | :stale_token
          | :denied

  @doc """
  Exchanges a raw delivery bearer for warm browser-session registry authority.

  Returns only opaque `browser_session_id` and `ticket_issue_id` on success.
  """
  @spec exchange(String.t(), keyword()) ::
          {:ok, %{browser_session_id: String.t(), ticket_issue_id: pos_integer()}}
          | {:error, exchange_error()}
  def exchange(raw_token, opts \\ []) when is_binary(raw_token) do
    redix_opts = Keyword.take(opts, [:redix_name])
    after_bind = Keyword.get(opts, :after_bind, :ok)

    with {:ok, browser_session_id} <- browser_session_id_opt(opts),
         {:ok, ticket_issue} <-
           ArtifactResolver.resolve_eligible_ticket_issue_from_delivery_token(raw_token),
         snapshot <- snapshot_from_issue(ticket_issue),
         {:ok, encoded} <-
           TicketSession.encode_binding(snapshot.generation, snapshot.fingerprint),
         {:ok, :bound} <-
           TicketSession.bind(
             browser_session_id,
             snapshot.ticket_issue_id,
             snapshot.generation,
             snapshot.fingerprint,
             TicketSession.session_idle_ttl_seconds(),
             redix_opts
           ),
         :ok <- invoke_after_bind(after_bind) do
      case post_bind_revalidate(raw_token, snapshot) do
        :ok ->
          {:ok,
           %{
             browser_session_id: browser_session_id,
             ticket_issue_id: snapshot.ticket_issue_id
           }}

        {:error, reason} ->
          _ = cleanup_binding(browser_session_id, snapshot.ticket_issue_id, encoded, redix_opts)
          {:error, reason}
      end
    else
      {:error, %ArtifactError{state: state}} ->
        {:error, map_artifact_state(state)}

      {:error, :registry_unavailable} ->
        {:error, :session_unavailable}

      {:error, :stale_generation} ->
        {:error, :stale_token}

      {:error, :generation_conflict} ->
        {:error, :denied}

      {:error, :invalid_binding} ->
        {:error, :denied}

      {:error, reason}
      when reason in [
             :invalid_token,
             :expired_token,
             :revoked_token,
             :not_ready,
             :not_scannable,
             :denied,
             :stale_token,
             :session_unavailable
           ] ->
        {:error, reason}
    end
  end

  defp browser_session_id_opt(opts) do
    case Keyword.get(opts, :browser_session_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:ok, TicketSession.new_browser_session_id()}
    end
  end

  defp snapshot_from_issue(%TicketIssue{} = ticket_issue) do
    hash = ticket_issue.delivery_token_hash

    %{
      ticket_issue_id: ticket_issue.id,
      generation: ticket_issue.delivery_token_generation,
      delivery_token_hash: hash,
      fingerprint: TicketSession.generation_fingerprint(hash)
    }
  end

  defp post_bind_revalidate(raw_token, snapshot) do
    with {:ok, fresh} <- reload_ticket_issue(snapshot.ticket_issue_id),
         :ok <- durable_snapshot_matches?(snapshot, fresh),
         :ok <- delivery_context_ok?(raw_token, fresh) do
      artifact_eligibility_ok?(raw_token)
    end
  end

  defp reload_ticket_issue(ticket_issue_id) do
    case Ash.get(TicketIssue, ticket_issue_id, authorize?: false) do
      {:ok, nil} -> {:error, :denied}
      {:ok, %TicketIssue{} = issue} -> {:ok, issue}
      {:error, _} -> {:error, :denied}
    end
  end

  defp durable_snapshot_matches?(snapshot, %TicketIssue{} = fresh) do
    cond do
      fresh.id != snapshot.ticket_issue_id ->
        {:error, :denied}

      fresh.delivery_token_generation != snapshot.generation ->
        {:error, :denied}

      fresh.delivery_token_hash != snapshot.delivery_token_hash ->
        {:error, :denied}

      true ->
        :ok
    end
  end

  defp delivery_context_ok?(raw_token, %TicketIssue{} = fresh) do
    token = String.trim(raw_token)

    case DeliveryToken.verify_context(token, Map.from_struct(fresh)) do
      :ok -> :ok
      {:error, :expired} -> {:error, :expired_token}
      {:error, :revoked} -> {:error, :revoked_token}
      {:error, :invalid} -> {:error, :invalid_token}
    end
  end

  defp artifact_eligibility_ok?(raw_token) do
    case ArtifactResolver.resolve_from_delivery_token(raw_token) do
      {:ok, _} ->
        :ok

      {:error, %ArtifactError{state: state}} ->
        {:error, map_artifact_state(state)}
    end
  end

  defp cleanup_binding(browser_session_id, ticket_issue_id, encoded, redix_opts) do
    TicketSession.conditional_remove(
      browser_session_id,
      ticket_issue_id,
      encoded,
      redix_opts
    )
  end

  defp invoke_after_bind(:ok), do: :ok

  defp invoke_after_bind(fun) when is_function(fun, 0) do
    fun.()
    :ok
  end

  defp map_artifact_state(:not_found), do: :invalid_token
  defp map_artifact_state(:expired_link), do: :expired_token
  defp map_artifact_state(:ticket_revoked), do: :revoked_token
  defp map_artifact_state(:ticket_not_ready), do: :not_ready
  defp map_artifact_state(:ticket_not_scannable), do: :not_scannable
  defp map_artifact_state(_other), do: :denied
end
