defmodule FastCheck.Sales.TicketDeliveryCoordinator do
  @moduledoc """
  Creates one durable initial delivery intent and send job for every issued
  ticket unit on a WhatsApp order.
  """

  require Ash.Query
  import Ecto.Query, only: [from: 2]

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Repo
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.Order
  alias FastCheck.Workers.SendWhatsAppTicketLinkWorker

  @page_size 50
  @system_actor %{actor_type: :system, actor_id: "ticket_delivery_coordinator"}

  @spec coordinate(pos_integer(), keyword()) ::
          {:ok, %{order_id: pos_integer(), intent_count: non_neg_integer()}}
          | {:ok, :manual_review | :not_whatsapp | :not_ticket_issued}
          | {:error, :invalid_order_id | :order_not_found | :retryable}
  def coordinate(order_id, opts \\ [])

  def coordinate(order_id, opts) when is_integer(order_id) and order_id > 0 do
    with {:ok, order} <- load_order(order_id) do
      cond do
        order.source_channel != "whatsapp" ->
          {:ok, :not_whatsapp}

        order.status != "ticket_issued" ->
          {:ok, :not_ticket_issued}

        true ->
          coordinate_whatsapp_order(order, opts)
      end
    end
  rescue
    _error -> {:error, :retryable}
  end

  def coordinate(_order_id, _opts), do: {:error, :invalid_order_id}

  defp coordinate_whatsapp_order(order, opts) do
    with {:ok, conversation} <- load_delivery_conversation(order),
         :ok <- validate_issued_unit_set(order.id),
         insert_job_fun <- Keyword.get(opts, :oban_insert_fun, &Oban.insert/1),
         {:ok, intent_count} <- coordinate_pages(order, conversation, insert_job_fun, 0, 0) do
      {:ok, %{order_id: order.id, intent_count: intent_count}}
    else
      {:manual_review, reason} ->
        open_manual_review(order.id, reason)

      {:error, :retryable} = error ->
        error
    end
  end

  defp load_delivery_conversation(%Order{sales_conversation_id: nil}),
    do: {:manual_review, "ticket_delivery_conversation_binding_missing"}

  defp load_delivery_conversation(%Order{sales_conversation_id: id} = order)
       when is_integer(id) and id > 0 do
    case Conversation
         |> Query.for_read(:get_by_id, %{id: id})
         |> Ash.read_one(authorize?: false) do
      {:ok, %Conversation{id: ^id, phone_e164: phone}} when phone == order.buyer_phone ->
        {:ok, %Conversation{id: id, phone_e164: phone}}

      {:ok, %Conversation{}} ->
        {:manual_review, "ticket_delivery_conversation_phone_mismatch"}

      {:ok, nil} ->
        {:manual_review, "ticket_delivery_conversation_binding_missing"}

      {:error, _reason} ->
        {:error, :retryable}
    end
  end

  defp load_delivery_conversation(_order),
    do: {:manual_review, "ticket_delivery_conversation_binding_missing"}

  defp validate_issued_unit_set(order_id) do
    result =
      Repo.query!(
        """
        WITH line_checks AS (
          SELECT
            line.id,
            line.quantity,
            count(issue.id) AS issue_count,
            count(issue.id) FILTER (
              WHERE issue.sales_order_id = line.sales_order_id
                AND issue.status = 'issued'
                AND issue.revoked_at IS NULL
                AND issue.line_item_sequence BETWEEN 1 AND line.quantity
            ) AS deliverable_count,
            count(DISTINCT issue.line_item_sequence) AS distinct_sequence_count,
            min(issue.line_item_sequence) AS first_sequence,
            max(issue.line_item_sequence) AS last_sequence
          FROM sales_order_lines AS line
          LEFT JOIN sales_ticket_issues AS issue
            ON issue.sales_order_line_id = line.id
          WHERE line.sales_order_id = $1
          GROUP BY line.id, line.sales_order_id, line.quantity
        ),
        order_totals AS (
          SELECT COALESCE(sum(quantity), 0)::bigint AS expected_count
          FROM sales_order_lines
          WHERE sales_order_id = $1
        ),
        issue_totals AS (
          SELECT
            count(*)::bigint AS issue_count,
            count(*) FILTER (
              WHERE issue.status != 'issued' OR issue.revoked_at IS NOT NULL
            )::bigint AS unsafe_count,
            count(*) FILTER (
              WHERE line.id IS NULL OR line.sales_order_id != issue.sales_order_id
            )::bigint AS ownership_conflict_count
          FROM sales_ticket_issues AS issue
          LEFT JOIN sales_order_lines AS line
            ON line.id = issue.sales_order_line_id
          WHERE issue.sales_order_id = $1
        )
        SELECT
          order_totals.expected_count,
          issue_totals.issue_count,
          issue_totals.unsafe_count,
          issue_totals.ownership_conflict_count,
          (SELECT count(*) FROM line_checks WHERE
            issue_count != quantity
            OR deliverable_count != quantity
            OR distinct_sequence_count != quantity
            OR first_sequence != 1
            OR last_sequence != quantity
          )::bigint AS incomplete_line_count
        FROM order_totals, issue_totals
        """,
        [order_id]
      )

    case result.rows do
      [[expected, issue_count, unsafe_count, ownership_conflict_count, incomplete_line_count]] ->
        cond do
          expected <= 0 -> {:manual_review, "ticket_delivery_issue_set_incomplete"}
          ownership_conflict_count > 0 -> {:manual_review, "ticket_delivery_issue_set_conflict"}
          unsafe_count > 0 -> {:manual_review, "ticket_delivery_issue_set_unsafe"}
          issue_count != expected -> {:manual_review, "ticket_delivery_issue_set_incomplete"}
          incomplete_line_count > 0 -> {:manual_review, "ticket_delivery_issue_set_incomplete"}
          true -> :ok
        end

      _other ->
        {:error, :retryable}
    end
  end

  defp coordinate_pages(order, conversation, insert_job_fun, last_id, total) do
    rows = load_issue_page(order.id, last_id)

    case rows do
      [] ->
        {:ok, total}

      _page ->
        case validate_issue_page(rows, order.id) do
          :ok ->
            case persist_page(order, conversation, rows, insert_job_fun) do
              {:ok, page_count} ->
                next_id = rows |> List.last() |> Map.fetch!(:id)
                coordinate_pages(order, conversation, insert_job_fun, next_id, total + page_count)

              {:manual_review, reason} ->
                {:manual_review, reason}

              {:error, :retryable} = error ->
                error
            end

          {:manual_review, reason} ->
            {:manual_review, reason}
        end
    end
  end

  defp load_issue_page(order_id, last_id) do
    Repo.query!(
      """
      SELECT issue.id, issue.sales_order_id, issue.sales_order_line_id,
             issue.line_item_sequence, issue.status, issue.revoked_at,
             line.sales_order_id AS line_order_id, line.quantity AS line_quantity
      FROM sales_ticket_issues AS issue
      LEFT JOIN sales_order_lines AS line
        ON line.id = issue.sales_order_line_id
      WHERE issue.sales_order_id = $1 AND issue.id > $2
      ORDER BY issue.id ASC
      LIMIT $3
      """,
      [order_id, last_id, @page_size]
    ).rows
    |> Enum.map(fn [
                     id,
                     sales_order_id,
                     line_id,
                     sequence,
                     status,
                     revoked_at,
                     line_order_id,
                     line_quantity
                   ] ->
      %{
        id: id,
        sales_order_id: sales_order_id,
        sales_order_line_id: line_id,
        line_item_sequence: sequence,
        status: status,
        revoked_at: revoked_at,
        line_order_id: line_order_id,
        line_quantity: line_quantity
      }
    end)
  end

  defp validate_issue_page(rows, order_id) do
    if Enum.all?(rows, fn issue ->
         issue.sales_order_id == order_id and issue.line_order_id == order_id and
           issue.status == "issued" and is_nil(issue.revoked_at) and
           is_integer(issue.line_item_sequence) and issue.line_item_sequence > 0 and
           is_integer(issue.line_quantity) and issue.line_item_sequence <= issue.line_quantity
       end) do
      :ok
    else
      {:manual_review, "ticket_delivery_issue_set_unsafe"}
    end
  end

  defp persist_page(order, conversation, rows, insert_job_fun) do
    case Repo.transaction(fn ->
           Enum.each(
             rows,
             &persist_issue_intent_and_job!(&1, order, conversation, insert_job_fun)
           )

           length(rows)
         end) do
      {:ok, count} -> {:ok, count}
      {:error, {:manual_review, reason}} -> {:manual_review, reason}
      {:error, _reason} -> {:error, :retryable}
    end
  end

  defp persist_issue_intent_and_job!(issue, order, conversation, insert_job_fun) do
    intent = create_or_load_initial_intent!(order, conversation, issue.id)

    if intent.status == "queued" do
      insert_send_job!(intent.id, insert_job_fun)
    end
  end

  defp insert_send_job!(intent_id, insert_job_fun) do
    job = SendWhatsAppTicketLinkWorker.new(%{"ticket_delivery_intent_id" => intent_id})

    case insert_job_fun.(job) do
      {:ok, _job} -> :ok
      {:error, _reason} -> Repo.rollback(:delivery_job_insert_failed)
    end
  end

  defp create_or_load_initial_intent!(order, conversation, ticket_issue_id) do
    Repo.query!(
      """
      INSERT INTO sales_ticket_delivery_intents
        (sales_order_id, ticket_issue_id, conversation_id, purpose, status, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'initial_ticket_delivery', 'queued', now(), now())
      ON CONFLICT (ticket_issue_id, purpose)
        WHERE purpose = 'initial_ticket_delivery'
      DO NOTHING
      """,
      [order.id, ticket_issue_id, conversation.id]
    )

    intent =
      Repo.one!(
        from(intent in "sales_ticket_delivery_intents",
          where:
            intent.ticket_issue_id == ^ticket_issue_id and
              intent.purpose == "initial_ticket_delivery",
          select: %{
            id: intent.id,
            sales_order_id: intent.sales_order_id,
            conversation_id: intent.conversation_id,
            status: intent.status
          }
        )
      )

    if intent.sales_order_id == order.id and intent.conversation_id == conversation.id do
      intent
    else
      Repo.rollback({:manual_review, "ticket_delivery_issue_set_conflict"})
    end
  end

  defp open_manual_review(order_id, reason) do
    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1)", [order_id])

        case load_order(order_id) do
          {:ok, %{status: "ticket_issued"} = order} ->
            attrs = %{
              manual_review_reason: reason,
              last_error_code: reason,
              last_error_message: "Ticket delivery requires manual review."
            }

            case order
                 |> Changeset.for_update(:mark_manual_review, attrs,
                   reason: reason,
                   actor: @system_actor
                 )
                 |> Ash.update(authorize?: false) do
              {:ok, _order} -> :manual_review
              {:error, _reason} -> Repo.rollback(:retryable)
            end

          {:ok, %{status: "manual_review"}} ->
            :manual_review

          {:ok, _other_status} ->
            :not_ticket_issued

          {:error, _reason} ->
            Repo.rollback(:retryable)
        end
      end)

    case result do
      {:ok, status} -> {:ok, status}
      {:error, _reason} -> {:error, :retryable}
    end
  end

  defp load_order(order_id) do
    case Order
         |> Query.for_read(:get_by_id, %{id: order_id})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :order_not_found}
      {:ok, order} -> {:ok, order}
      {:error, _reason} -> {:error, :retryable}
    end
  end
end
