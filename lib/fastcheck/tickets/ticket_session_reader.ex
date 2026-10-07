defmodule FastCheck.Tickets.TicketSessionReader do
  @moduledoc """
  P1E-D1 internal browser-session ticket read authority.

  Validates Redis generation/fingerprint bindings against durable Postgres state,
  shares artifact eligibility via `ArtifactResolver`, and closes rotation races with
  a final durable re-read before optional session TTL refresh. HTTP routes are P1E-D2.
  """

  alias Ash
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Tickets.Artifact
  alias FastCheck.Tickets.ArtifactError
  alias FastCheck.Tickets.ArtifactResolver
  alias FastCheck.Tickets.DeliveryToken
  alias FastCheck.Tickets.TicketSession

  @type resolve_error ::
          :not_found
          | :expired_link
          | :ticket_revoked
          | :ticket_not_ready
          | :ticket_not_scannable
          | :session_unavailable

  @doc """
  Resolves a customer ticket artifact for one ticket issue within a browser session.

  `ticket_issue_id` is a route selector only; authority comes from the Redis binding.
  """
  @spec resolve(String.t(), pos_integer(), keyword()) ::
          {:ok, Artifact.t()} | {:error, resolve_error()}
  def resolve(browser_session_id, ticket_issue_id, opts \\ [])

  def resolve(browser_session_id, ticket_issue_id, opts)
      when is_binary(browser_session_id) and browser_session_id != "" and
             is_integer(ticket_issue_id) and ticket_issue_id > 0 do
    redix_opts = Keyword.take(opts, [:redix_name])
    after_artifact = Keyword.get(opts, :after_artifact, :ok)

    case TicketSession.fetch_binding(browser_session_id, ticket_issue_id, redix_opts) do
      {:ok, binding} ->
        resolve_with_binding(
          browser_session_id,
          ticket_issue_id,
          binding,
          after_artifact,
          redix_opts
        )

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :invalid_binding} ->
        {:error, :not_found}

      {:error, :registry_unavailable} ->
        {:error, :session_unavailable}
    end
  end

  def resolve(_browser_session_id, _ticket_issue_id, _opts), do: {:error, :not_found}

  defp resolve_with_binding(
         browser_session_id,
         ticket_issue_id,
         binding,
         after_artifact,
         redix_opts
       ) do
    encoded = binding.encoded

    with {:ok, ticket_issue} <- load_ticket_issue(ticket_issue_id),
         :ok <- binding_matches_durable?(binding, ticket_issue),
         :ok <- durable_delivery_context_ok?(ticket_issue),
         {:ok, _artifact} <- ArtifactResolver.resolve_from_ticket_issue(ticket_issue),
         :ok <- invoke_after_artifact(after_artifact),
         {:ok, fresh} <- load_ticket_issue(ticket_issue_id),
         :ok <- final_durable_authority_ok?(binding, fresh),
         :ok <- refresh_session_ttl(browser_session_id, redix_opts) do
      ArtifactResolver.resolve_from_ticket_issue(fresh)
      |> map_artifact_result()
    else
      {:error, :expired_link} = error ->
        invalidate_binding(browser_session_id, ticket_issue_id, encoded, redix_opts)
        error

      {:error, :ticket_revoked} = error ->
        invalidate_binding(browser_session_id, ticket_issue_id, encoded, redix_opts)
        error

      {:error, %ArtifactError{state: state}} ->
        invalidate_terminal(browser_session_id, ticket_issue_id, encoded, state, redix_opts)
        {:error, map_artifact_state(state)}

      {:error, :binding_mismatch} ->
        invalidate_binding(browser_session_id, ticket_issue_id, encoded, redix_opts)
        {:error, :not_found}

      {:error, :missing_ticket_issue} ->
        invalidate_binding(browser_session_id, ticket_issue_id, encoded, redix_opts)
        {:error, :not_found}

      {:error, :session_unavailable} ->
        {:error, :session_unavailable}

      {:error, :final_authority_denied} ->
        invalidate_binding(browser_session_id, ticket_issue_id, encoded, redix_opts)
        {:error, :not_found}
    end
  end

  defp load_ticket_issue(ticket_issue_id) do
    case Ash.get(TicketIssue, ticket_issue_id, authorize?: false) do
      {:ok, nil} -> {:error, :missing_ticket_issue}
      {:ok, %TicketIssue{} = issue} -> {:ok, issue}
      {:error, _} -> {:error, :session_unavailable}
    end
  end

  defp binding_matches_durable?(binding, %TicketIssue{} = ticket_issue) do
    db_generation = ticket_issue.delivery_token_generation
    db_hash = ticket_issue.delivery_token_hash

    if binding.generation == db_generation and
         binding.fingerprint == TicketSession.generation_fingerprint(db_hash) do
      :ok
    else
      {:error, :binding_mismatch}
    end
  end

  defp durable_delivery_context_ok?(%TicketIssue{} = ticket_issue) do
    cond do
      DeliveryToken.revoked?(ticket_issue) ->
        {:error, :ticket_revoked}

      delivery_expired?(ticket_issue.delivery_token_expires_at) ->
        {:error, :expired_link}

      true ->
        :ok
    end
  end

  defp delivery_expired?(nil), do: true

  defp delivery_expired?(%DateTime{} = expires_at) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  defp final_durable_authority_ok?(binding, %TicketIssue{} = fresh) do
    cond do
      DeliveryToken.revoked?(fresh) ->
        {:error, :final_authority_denied}

      delivery_expired?(fresh.delivery_token_expires_at) ->
        {:error, :final_authority_denied}

      binding_matches_durable?(binding, fresh) == :ok ->
        :ok

      true ->
        {:error, :final_authority_denied}
    end
  end

  defp refresh_session_ttl(browser_session_id, redix_opts) do
    case TicketSession.refresh_ttl_if_exists(
           browser_session_id,
           TicketSession.session_idle_ttl_seconds(),
           redix_opts
         ) do
      {:ok, _} -> :ok
      {:error, :registry_unavailable} -> {:error, :session_unavailable}
    end
  end

  defp invalidate_terminal(browser_session_id, ticket_issue_id, encoded, state, redix_opts) do
    if terminal_invalidation?(state) do
      invalidate_binding(browser_session_id, ticket_issue_id, encoded, redix_opts)
    else
      :ok
    end
  end

  defp terminal_invalidation?(state) do
    state in [
      :expired_link,
      :ticket_revoked,
      :ticket_not_ready,
      :ticket_not_scannable,
      :not_found
    ]
  end

  defp invalidate_binding(browser_session_id, ticket_issue_id, encoded, redix_opts)
       when is_binary(encoded) do
    _ =
      TicketSession.conditional_remove(
        browser_session_id,
        ticket_issue_id,
        encoded,
        redix_opts
      )

    :ok
  end

  defp invoke_after_artifact(:ok), do: :ok

  defp invoke_after_artifact(fun) when is_function(fun, 0) do
    fun.()
    :ok
  end

  defp map_artifact_result({:ok, artifact}), do: {:ok, artifact}

  defp map_artifact_result({:error, %ArtifactError{state: state}}),
    do: {:error, map_artifact_state(state)}

  defp map_artifact_state(:not_found), do: :not_found
  defp map_artifact_state(:expired_link), do: :expired_link
  defp map_artifact_state(:ticket_revoked), do: :ticket_revoked
  defp map_artifact_state(:ticket_not_ready), do: :ticket_not_ready
  defp map_artifact_state(:ticket_not_scannable), do: :ticket_not_scannable
  defp map_artifact_state(_other), do: :not_found
end
