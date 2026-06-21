defmodule FastCheck.Sales.TicketPage do
  @moduledoc """
  VS-11 customer secure ticket page domain boundary.

  Classifies delivery bearer tokens into customer-safe display states and returns
  only approved fields. Read-only: no issuance, delivery, payment, or scanner mutation.
  """

  import Ecto.Query, only: [from: 2]

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Tickets.{DeliveryToken, QrPayload, TokenHash}

  @type display_state ::
          :valid
          | :not_found
          | :expired_link
          | :ticket_revoked
          | :ticket_not_scannable
          | :ticket_not_ready

  @type result :: %{
          state: display_state(),
          event_name: String.t() | nil,
          attendee_name: String.t() | nil,
          ticket_type: String.t() | nil,
          qr_payload: String.t() | nil,
          support_message: String.t()
        }

  @token_charset ~r/^[A-Za-z0-9_-]+$/
  @min_token_length 16
  @max_token_length 128

  @doc """
  Resolves a raw route delivery token into a customer-safe ticket page result.

  Never raises on missing attendee, event, or ticket issue rows.
  """
  @spec resolve(String.t()) :: result()
  def resolve(raw_token) when is_binary(raw_token) do
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
      valid_result(ticket_issue, attendee, event)
    else
      {:error, :not_found} -> not_found_result()
      {:error, :expired_link} -> expired_link_result()
      {:error, :ticket_revoked} -> ticket_revoked_result()
      {:error, :ticket_not_ready} -> ticket_not_ready_result()
      {:error, :ticket_not_scannable} -> ticket_not_scannable_result()
      :error -> not_found_result()
    end
  end

  def resolve(_), do: not_found_result()

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
      {:error, _} -> {:error, :not_found}
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

  defp ensure_issued_status(%{status: "issued"}), do: :ok
  defp ensure_issued_status(_), do: {:error, :ticket_not_ready}

  defp load_attendee(%{attendee_id: attendee_id}) when is_integer(attendee_id) do
    case Repo.get(Attendee, attendee_id) do
      %Attendee{} = attendee -> {:ok, attendee}
      nil -> {:error, :ticket_not_ready}
    end
  end

  defp load_attendee(_), do: {:error, :ticket_not_ready}

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

      _ ->
        {:error, :ticket_not_ready}
    end
  end

  defp load_event(_), do: {:error, :ticket_not_ready}

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

  defp valid_result(ticket_issue, attendee, event) do
    %{
      state: :valid,
      event_name: event.name,
      attendee_name: attendee_display_name(attendee),
      ticket_type: attendee.ticket_type,
      qr_payload: QrPayload.build_for_scanner(ticket_issue.ticket_code),
      support_message: "Present this ticket code at the entrance scanner."
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

  defp not_found_result do
    %{
      state: :not_found,
      event_name: nil,
      attendee_name: nil,
      ticket_type: nil,
      qr_payload: nil,
      support_message: "This ticket link is not available. It may be invalid or expired."
    }
  end

  defp expired_link_result do
    %{
      state: :expired_link,
      event_name: nil,
      attendee_name: nil,
      ticket_type: nil,
      qr_payload: nil,
      support_message: "This ticket link has expired. Please contact event support for help."
    }
  end

  defp ticket_revoked_result do
    %{
      state: :ticket_revoked,
      event_name: nil,
      attendee_name: nil,
      ticket_type: nil,
      qr_payload: nil,
      support_message: "This ticket has been cancelled. Please contact event support."
    }
  end

  defp ticket_not_scannable_result do
    %{
      state: :ticket_not_scannable,
      event_name: nil,
      attendee_name: nil,
      ticket_type: nil,
      qr_payload: nil,
      support_message: "This ticket is no longer valid for entry. Please contact event support."
    }
  end

  defp ticket_not_ready_result do
    %{
      state: :ticket_not_ready,
      event_name: nil,
      attendee_name: nil,
      ticket_type: nil,
      qr_payload: nil,
      support_message: "Your ticket is not ready yet. Please try again later or contact support."
    }
  end
end
