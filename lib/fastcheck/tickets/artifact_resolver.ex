defmodule FastCheck.Tickets.ArtifactResolver do
  @moduledoc """
  Read-only resolver from delivery bearer token to a customer-facing ticket artifact.

  This module mirrors the secure ticket page eligibility policy without taking
  over payment, issuance, scanner, revocation, or delivery authority.
  """

  import Ecto.Query, only: [from: 2]

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Tickets.Artifact
  alias FastCheck.Tickets.ArtifactError
  alias FastCheck.Tickets.DeliveryToken
  alias FastCheck.Tickets.QrPayload
  alias FastCheck.Tickets.TokenHash

  @type result :: {:ok, Artifact.t()} | {:error, ArtifactError.t()}

  @token_charset ~r/^[A-Za-z0-9_-]+$/
  @min_token_length 16
  @max_token_length 128

  @doc """
  Resolves a raw delivery bearer token into a safe artifact or safe error.

  This function is request-local and read-only. It does not mutate ticket,
  attendee, scanner, payment, delivery, or audit state.
  """
  @spec resolve_from_delivery_token(term()) :: result()
  def resolve_from_delivery_token(raw_token) when is_binary(raw_token) do
    token = String.trim(raw_token)

    with :ok <- validate_token_format(token),
         hash <- TokenHash.hash(token, :delivery),
         {:ok, ticket_issue} <- fetch_ticket_issue(hash),
         :ok <- verify_delivery_context(token, ticket_issue),
         :ok <- ensure_issued_status(ticket_issue),
         {:ok, attendee} <- load_attendee(ticket_issue),
         {:ok, event} <- load_event(ticket_issue),
         :ok <- ensure_event_available(event),
         :ok <- ensure_scannable(attendee) do
      {:ok, artifact(ticket_issue, attendee, event)}
    else
      {:error, state} -> {:error, error(state)}
      :error -> {:error, error(:not_found)}
    end
  end

  def resolve_from_delivery_token(_raw_token), do: {:error, error(:not_found)}

  @doc """
  Resolves a ticket issue id into a backend/admin ticket artifact.

  This function is request-local and read-only. It relies on the caller being
  protected by dashboard BrowserAuth, validates the actor as an admin, and then
  performs a narrow internal ticket issue lookup. It does not verify delivery
  tokens and does not check delivery-token expiry.
  """
  @spec resolve_for_admin_ticket_issue(map(), term()) :: result()
  def resolve_for_admin_ticket_issue(actor, ticket_issue_id) do
    with :ok <- require_admin_actor(actor),
         {:ok, id} <- parse_positive_integer(ticket_issue_id),
         {:ok, ticket_issue} <- fetch_ticket_issue_by_id(id),
         :ok <- ensure_issued_status(ticket_issue),
         :ok <- ensure_scanner_not_revoked(ticket_issue),
         {:ok, attendee} <- load_attendee(ticket_issue),
         {:ok, event} <- load_event(ticket_issue),
         :ok <- ensure_event_available(event),
         :ok <- ensure_scannable(attendee) do
      {:ok, artifact(ticket_issue, attendee, event)}
    else
      {:error, state} -> {:error, error(state)}
      :error -> {:error, error(:not_found)}
    end
  end

  defp validate_token_format(token) do
    cond do
      token == "" ->
        {:error, :not_found}

      String.length(token) < @min_token_length or String.length(token) > @max_token_length ->
        {:error, :not_found}

      not Regex.match?(@token_charset, token) ->
        {:error, :not_found}

      true ->
        :ok
    end
  end

  defp fetch_ticket_issue(hash) do
    case TicketIssue
         |> Ash.Query.for_read(:get_by_delivery_token_hash, %{delivery_token_hash: hash})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, ticket_issue} -> {:ok, ticket_issue}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp fetch_ticket_issue_by_id(id) do
    case TicketIssue
         |> Ash.Query.for_read(:get_by_id, %{id: id})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, ticket_issue} -> {:ok, ticket_issue}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp verify_delivery_context(token, ticket_issue) do
    case DeliveryToken.verify_context(token, Map.from_struct(ticket_issue)) do
      :ok -> :ok
      {:error, :expired} -> {:error, :expired_link}
      {:error, :revoked} -> {:error, :ticket_revoked}
      {:error, :invalid} -> {:error, :not_found}
    end
  end

  defp require_admin_actor(actor) do
    if actor_type(actor) == :admin, do: :ok, else: {:error, :not_found}
  end

  defp actor_type(actor) when is_map(actor) do
    Map.get(actor, :actor_type) || Map.get(actor, "actor_type")
  end

  defp actor_type(_actor), do: nil

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp parse_positive_integer(_value), do: {:error, :not_found}

  defp ensure_issued_status(%{status: "issued"}), do: :ok
  defp ensure_issued_status(%{status: "revoked"}), do: {:error, :ticket_revoked}
  defp ensure_issued_status(_ticket_issue), do: {:error, :ticket_not_ready}

  defp ensure_scanner_not_revoked(%{scanner_status: "revoked"}), do: {:error, :ticket_revoked}
  defp ensure_scanner_not_revoked(_ticket_issue), do: :ok

  defp load_attendee(%{attendee_id: attendee_id}) when is_integer(attendee_id) do
    case Repo.get(Attendee, attendee_id) do
      %Attendee{} = attendee -> {:ok, attendee}
      nil -> {:error, :ticket_not_ready}
    end
  end

  defp load_attendee(_ticket_issue), do: {:error, :ticket_not_ready}

  defp load_event(%{sales_order_id: sales_order_id}) when is_integer(sales_order_id) do
    event_id =
      Repo.one(
        from o in "sales_orders",
          where: o.id == ^sales_order_id,
          select: o.event_id
      )

    case event_id do
      id when is_integer(id) ->
        case Repo.get(Event, id) do
          %Event{} = event -> {:ok, event}
          nil -> {:error, :ticket_not_ready}
        end

      _other ->
        {:error, :ticket_not_ready}
    end
  end

  defp load_event(_ticket_issue), do: {:error, :ticket_not_ready}

  defp ensure_event_available(%Event{status: "archived"}), do: {:error, :ticket_not_ready}
  defp ensure_event_available(%Event{}), do: :ok

  defp ensure_scannable(%Attendee{scan_eligibility: "not_scannable"}),
    do: {:error, :ticket_not_scannable}

  defp ensure_scannable(%Attendee{scan_eligibility: eligibility, payment_status: payment_status})
       when eligibility in [nil, "active"] do
    if payment_status_valid?(payment_status) do
      :ok
    else
      {:error, :ticket_not_scannable}
    end
  end

  defp ensure_scannable(%Attendee{}), do: {:error, :ticket_not_scannable}

  # Mirrors FastCheck.Attendees.Scan payment acceptance without coupling to scan mutation.
  defp payment_status_valid?(status) do
    normalized = normalize_payment_status(status)
    normalized == "completed" or (normalized == "unknown" and allow_unknown_payment_status?())
  end

  defp normalize_payment_status(nil), do: "unknown"

  defp normalize_payment_status(status) when is_binary(status) do
    normalized =
      status
      |> String.trim()
      |> String.downcase()
      |> String.replace_prefix("wc-", "")

    cond do
      normalized == "" -> "unknown"
      Regex.match?(~r/\bcompleted?\b/, normalized) -> "completed"
      true -> normalized
    end
  end

  defp allow_unknown_payment_status? do
    Application.get_env(:fastcheck, :allow_unknown_payment_status, false)
  end

  defp artifact(ticket_issue, attendee, event) do
    %Artifact{
      state: :valid,
      event_name: event.name,
      attendee_name: attendee_display_name(attendee),
      ticket_type: attendee.ticket_type,
      scanner_payload: QrPayload.build_for_scanner(ticket_issue.ticket_code),
      scanner_payload_format: :plain_ticket_code,
      support_message: "Present this ticket code at the entrance scanner.",
      issued_at: ticket_issue.issued_at,
      delivery_expires_at: ticket_issue.delivery_token_expires_at,
      event_date: event.event_date,
      event_time: event.event_time,
      event_location: event.location,
      entrance_name: event.entrance_name
    }
  end

  defp attendee_display_name(%Attendee{first_name: first, last_name: last}) do
    [first, last]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      name -> name
    end
  end

  defp error(state) do
    %ArtifactError{
      state: state,
      support_message: support_message(state),
      http_status_hint: http_status_hint(state)
    }
  end

  defp support_message(:not_found),
    do: "This ticket link is not available. It may be invalid or expired."

  defp support_message(:expired_link),
    do: "This ticket link has expired. Please contact event support for help."

  defp support_message(:ticket_revoked),
    do: "This ticket has been cancelled. Please contact event support."

  defp support_message(:ticket_not_scannable),
    do: "This ticket is no longer valid for entry. Please contact event support."

  defp support_message(:ticket_not_ready),
    do: "Your ticket is not ready yet. Please try again later or contact support."

  defp http_status_hint(:not_found), do: :not_found
  defp http_status_hint(:expired_link), do: :gone
  defp http_status_hint(_state), do: :ok
end
