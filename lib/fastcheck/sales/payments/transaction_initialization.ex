defmodule FastCheck.Sales.Payments.TransactionInitialization do
  @moduledoc """
  Approved Sales payment initialization boundary for Paystack.

  Connects valid checkout sessions to `FastCheck.Payments.Paystack.TransactionInitializer`
  with durable idempotency, concurrency safety, and stale-initializing handling.
  Does not verify payment, issue tickets, or mutate inventory.
  """

  require Logger

  require Ash.Query

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Observability.Correlation
  alias FastCheck.Payments.Paystack.Config, as: PaystackConfig
  alias FastCheck.Payments.Paystack.Error, as: PaystackError
  alias FastCheck.Payments.Paystack.TransactionInitializer
  alias FastCheck.Repo
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.OrderLine
  alias FastCheck.Sales.PaymentAttempt

  @checkout_actor_types [:system, :admin, :customer_session]
  @payable_order_statuses ["awaiting_payment"]
  @valid_session_statuses_for_new_init ["hold_attached"]
  @valid_session_statuses_for_replay ["payment_link_sent"]

  @type init_success :: %{
          payment_attempt_id: integer(),
          provider: :paystack,
          provider_reference: String.t(),
          authorization_url: String.t(),
          status: :initialized,
          idempotent?: boolean()
        }

  @spec initialize_for_checkout_session(integer(), map(), keyword()) ::
          {:ok, init_success()}
          | {:error, atom() | map()}
  def initialize_for_checkout_session(session_id, actor, opts \\ [])
      when is_integer(session_id) do
    context = build_context(actor, opts)

    with {:ok, session} <- load_session(session_id),
         {:ok, order} <- load_order(session.sales_order_id),
         :ok <- authorize_actor(actor, order),
         :ok <- validate_order(order),
         :ok <- validate_session_for_init(session),
         {:ok, lines} <- load_order_lines(order),
         :ok <- validate_amounts(order, lines),
         :ok <- validate_hold(session, lines),
         :ok <- validate_buyer_email(order) do
      idempotency_key = idempotency_key(session, order)

      case maybe_idempotent_replay(session, order, idempotency_key) do
        {:ok, replay} when not is_nil(replay) ->
          {:ok, replay}

        {:ok, nil} ->
          do_initialize(session, order, idempotency_key, context)

        {:error, _} = error ->
          error
      end
    end
  end

  defp build_context(actor, opts) do
    correlation_id =
      %{
        correlation_id: Keyword.get(opts, :correlation_id),
        request_id: Keyword.get(opts, :request_id)
      }
      |> Correlation.ensure_correlation_id()

    %{
      actor: actor,
      correlation_id: correlation_id,
      source_channel: Keyword.get(opts, :source_channel) || Map.get(actor, :source_channel),
      transition_metadata: %{
        source_channel: Keyword.get(opts, :source_channel) || Map.get(actor, :source_channel)
      }
    }
  end

  defp load_session(session_id) do
    case CheckoutSession
         |> Query.for_read(:get_by_id, %{id: session_id})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :checkout_session_not_found}
      {:ok, session} -> {:ok, session}
      {:error, _} = error -> error
    end
  end

  defp load_order(order_id) do
    case Order
         |> Query.for_read(:get_by_id, %{id: order_id})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :order_not_found}
      {:ok, order} -> {:ok, order}
      {:error, _} = error -> error
    end
  end

  defp authorize_actor(%{actor_type: actor_type, allowed_event_ids: ids}, %{event_id: event_id})
       when actor_type in @checkout_actor_types and is_list(ids) do
    if event_id in ids, do: :ok, else: {:error, :forbidden}
  end

  defp authorize_actor(%{actor_type: :system}, %{event_id: _}), do: :ok
  defp authorize_actor(_, _), do: {:error, :forbidden}

  defp validate_order(%{status: status}) when status in ["cancelled", "expired", "refunded"],
    do: {:error, invalid_order_error(status)}

  defp validate_order(%{status: "ticket_issued"}),
    do: {:error, invalid_order_error("ticket_issued")}

  defp validate_order(%{status: status}) when status in @payable_order_statuses, do: :ok

  defp validate_order(%{status: status}),
    do: {:error, invalid_order_error(status)}

  defp validate_order_expiry(%{expires_at: nil}), do: :ok

  defp validate_order_expiry(%{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :order_expired}
  end

  defp validate_session_for_init(%{status: status, expires_at: expires_at}) do
    cond do
      status in @valid_session_statuses_for_new_init ->
        validate_session_expiry(expires_at)

      status in @valid_session_statuses_for_replay ->
        :ok

      true ->
        {:error, invalid_session_error(status)}
    end
  end

  defp validate_session_expiry(nil), do: :ok

  defp validate_session_expiry(expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :checkout_session_expired}
  end

  defp validate_hold(%{redis_hold_key: key, hold_quantity: hold_qty}, lines)
       when is_binary(key) and key != "" do
    line_qty = Enum.map(lines, & &1.quantity) |> Enum.sum()

    if hold_qty == line_qty, do: :ok, else: {:error, :hold_quantity_mismatch}
  end

  defp validate_hold(_, _), do: {:error, :hold_not_attached}

  defp load_order_lines(order) do
    case OrderLine
         |> Query.for_read(:list_for_order, %{sales_order_id: order.id})
         |> Ash.read(authorize?: false) do
      {:ok, []} -> {:error, :invalid_order_state}
      {:ok, lines} -> {:ok, lines}
      {:error, _} = error -> error
    end
  end

  defp validate_amounts(order, lines) do
    line_total =
      lines
      |> Enum.map(& &1.total_amount_cents)
      |> Enum.sum()

    cond do
      order.total_amount_cents <= 0 ->
        {:error, :invalid_order_amount}

      line_total != order.total_amount_cents ->
        {:error, :invalid_order_amount}

      true ->
        :ok
    end
  end

  defp validate_buyer_email(%{buyer_email: email}) when is_binary(email) and email != "",
    do: :ok

  defp validate_buyer_email(_), do: {:error, :missing_buyer_email}

  defp idempotency_key(session, order),
    do: "paystack:init:#{order.id}:#{session.id}"

  defp maybe_idempotent_replay(session, order, idempotency_key) do
    with :ok <- validate_order_expiry(order) do
      case {session.status, lookup_active_attempt(idempotency_key)} do
        {"payment_link_sent", :no_active_attempt} ->
          {:error, invalid_session_error("payment_link_sent")}

        {_, :no_active_attempt} ->
          {:ok, nil}

        {_, {:ok, attempt}} ->
          handle_existing_attempt(attempt, order, session)
      end
    end
  end

  defp lookup_active_attempt(idempotency_key) do
    case PaymentAttempt
         |> Query.for_read(:get_active_by_idempotency_key, %{idempotency_key: idempotency_key})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> :no_active_attempt
      {:ok, attempt} -> {:ok, attempt}
      {:error, _} = error -> error
    end
  end

  defp handle_existing_attempt(%{status: "initialized"} = attempt, order, _session) do
    cond do
      amount_mismatch?(attempt, order) ->
        mark_amount_mismatch(attempt, order)

      is_binary(attempt.authorization_url) and attempt.authorization_url != "" ->
        {:ok, success_result(attempt, true)}

      true ->
        {:error, :invalid_payment_attempt_state}
    end
  end

  defp handle_existing_attempt(%{status: "initializing"} = attempt, order, _session) do
    if amount_mismatch?(attempt, order) do
      mark_amount_mismatch(attempt, order)
    else
      if stale_initializing?(attempt) do
        mark_stale_initializing(attempt, order)
      else
        {:error, :payment_initialization_in_progress}
      end
    end
  end

  defp mark_amount_mismatch(attempt, order) do
    context = service_context(order)

    _ =
      attempt
      |> Changeset.for_update(
        :mark_manual_review,
        %{manual_review_reason: "amount_changed"},
        actor: context.actor
      )
      |> Ash.update(authorize?: false, context: context)

    {:error, amount_changed_error()}
  end

  defp stale_initializing?(%{inserted_at: inserted_at}) do
    stale_after = Application.get_env(:fastcheck, :paystack_initializing_stale_after_seconds, 120)
    age_seconds = DateTime.diff(DateTime.utc_now(), inserted_at, :second)
    age_seconds >= stale_after
  end

  defp mark_stale_initializing(attempt, order) do
    context = service_context(order)

    case attempt
         |> Changeset.for_update(
           :mark_manual_review,
           %{manual_review_reason: "stale_initialization"},
           actor: context.actor
         )
         |> Ash.update(authorize?: false, context: context) do
      {:ok, _} ->
        {:error,
         %{
           type: :stale_initialization,
           safe_message: "Payment initialization requires manual review",
           retryable?: false,
           safe_metadata: %{order_public_reference: order.public_reference}
         }}

      {:error, _} = error ->
        error
    end
  end

  defp do_initialize(session, order, idempotency_key, context) do
    case reserve_initializing_attempt(session, order, idempotency_key, context) do
      {:ok, %{idempotent?: _} = replay} ->
        {:ok, replay}

      {:ok, attempt} ->
        case call_paystack(order, attempt, context) do
          {:ok, result} -> finalize_success(session, attempt, result, context)
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp reserve_initializing_attempt(_session, order, idempotency_key, context) do
    provider_reference = generate_provider_reference(order)

    order.id
    |> lock_and_reserve_attempt(idempotency_key, provider_reference, order, context)
    |> normalize_reserve_result(order)
  end

  defp lock_and_reserve_attempt(order_id, idempotency_key, provider_reference, order, context) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [order_id])
      handle_locked_attempt_lookup(idempotency_key, provider_reference, order, context)
    end)
  end

  defp handle_locked_attempt_lookup(idempotency_key, provider_reference, order, context) do
    case lookup_active_attempt(idempotency_key) do
      {:ok, %{status: "initialized"} = attempt} ->
        Repo.rollback({:idempotent_replay, success_result(attempt, true)})

      {:ok, %{status: "initializing"} = attempt} ->
        rollback_initializing_conflict(attempt)

      :no_active_attempt ->
        create_initializing_in_txn(order, provider_reference, idempotency_key, context)
    end
  end

  defp rollback_initializing_conflict(attempt) do
    if stale_initializing?(attempt) do
      Repo.rollback({:stale_initializing, attempt})
    else
      Repo.rollback(:payment_initialization_in_progress)
    end
  end

  defp create_initializing_in_txn(order, provider_reference, idempotency_key, context) do
    attrs = %{
      sales_order_id: order.id,
      provider: "paystack",
      provider_reference: provider_reference,
      idempotency_key: idempotency_key,
      amount_cents: order.total_amount_cents,
      currency: order.currency
    }

    case PaymentAttempt
         |> Changeset.for_create(:create_initializing, attrs, actor: context.actor)
         |> Ash.create(authorize?: false, context: context, return_notifications?: true) do
      {:ok, attempt, notifications} ->
        Ash.Notifier.notify(notifications)
        attempt

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp normalize_reserve_result(result, order) do
    case result do
      {:ok, attempt} when is_struct(attempt, PaymentAttempt) ->
        {:ok, attempt}

      {:ok, %{idempotent?: _} = replay} ->
        {:ok, replay}

      {:error, {:idempotent_replay, replay}} ->
        {:ok, replay}

      {:error, :payment_initialization_in_progress} ->
        {:error, :payment_initialization_in_progress}

      {:error, {:stale_initializing, attempt}} ->
        mark_stale_initializing(attempt, order)

      {:error, error} ->
        {:error, error}
    end
  end

  defp call_paystack(order, attempt, context) do
    params = %{
      amount_cents: order.total_amount_cents,
      currency: order.currency,
      email: order.buyer_email,
      reference: attempt.provider_reference,
      callback_url: Application.get_env(:fastcheck, :paystack_callback_url),
      metadata: paystack_metadata(order, attempt, context)
    }

    correlation_opts = [correlation_id: context.correlation_id]

    log_safe_start(order, attempt, context)

    case TransactionInitializer.initialize(params, correlation_opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, %PaystackError{} = error} ->
        _ = mark_provider_failure(attempt, order, error, context)
        {:error, normalize_provider_error(error)}
    end
  end

  defp finalize_success(session, attempt, result, context) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, attempt} <-
           attempt
           |> Changeset.for_update(
             :mark_initialized,
             %{
               authorization_url: result.authorization_url,
               access_code: result.access_code,
               raw_initialize_response: result.safe_data,
               initialized_at: now
             },
             actor: context.actor
           )
           |> Ash.update(authorize?: false, context: context),
         :ok <- maybe_mark_payment_link_sent(session, context) do
      {:ok, success_result(attempt, false)}
    end
  end

  defp maybe_mark_payment_link_sent(%{status: "hold_attached"} = session, context) do
    case session
         |> Changeset.for_update(:mark_payment_link_sent, %{}, actor: context.actor)
         |> Ash.update(authorize?: false, context: context) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_mark_payment_link_sent(%{status: "payment_link_sent"}, _context), do: :ok

  defp maybe_mark_payment_link_sent(_, _),
    do: {:error, :invalid_checkout_session_state}

  defp mark_provider_failure(attempt, order, error, context) do
    attrs = %{
      failure_code: to_string(error.type),
      failure_message: PaystackError.sanitize_message(error.message)
    }

    _ =
      attempt
      |> Changeset.for_update(:mark_failed, attrs, actor: context.actor)
      |> Ash.update(authorize?: false, context: service_context(order))

    :ok
  end

  defp generate_provider_reference(order) do
    suffix =
      :crypto.strong_rand_bytes(4)
      |> Base.encode16(case: :lower)

    safe_public =
      order.public_reference
      |> String.replace("_", "-")
      |> String.replace(~r/[^A-Za-z0-9.\-=]/, "")

    reference = "FC-#{safe_public}-#{suffix}"

    case PaystackConfig.normalize_reference(reference) do
      {:ok, normalized} -> normalized
      {:error, _} -> "FC-#{order.id}-#{suffix}"
    end
  end

  defp paystack_metadata(order, attempt, context) do
    %{
      order_public_reference: order.public_reference,
      event_id: order.event_id,
      source_channel: context.source_channel,
      correlation_id: context.correlation_id,
      checkout_session_id: attempt_idempotency_session_id(attempt.idempotency_key)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp attempt_idempotency_session_id("paystack:init:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [_order_id, session_id] -> String.to_integer(session_id)
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp attempt_idempotency_session_id(_), do: nil

  defp amount_mismatch?(attempt, order) do
    attempt.amount_cents != order.total_amount_cents or attempt.currency != order.currency
  end

  defp success_result(attempt, idempotent?) do
    %{
      payment_attempt_id: attempt.id,
      provider: :paystack,
      provider_reference: attempt.provider_reference,
      authorization_url: attempt.authorization_url,
      status: :initialized,
      idempotent?: idempotent?
    }
  end

  defp service_context(order) do
    %{
      actor: %{actor_type: :system, actor_id: "payment_init"},
      correlation_id: Correlation.generate_correlation_id(),
      transition_metadata: %{public_reference: order.public_reference}
    }
  end

  defp normalize_provider_error(%PaystackError{} = error) do
    %{
      type: error.type,
      safe_message: PaystackError.sanitize_message(error.message),
      retryable?: error.retryable?,
      safe_metadata: Map.get(error, :safe_metadata, %{})
    }
  end

  defp invalid_order_error(status) do
    %{
      type: :invalid_order_state,
      safe_message: "Order cannot initialize payment",
      retryable?: false,
      safe_metadata: %{status: status}
    }
  end

  defp invalid_session_error(status) do
    %{
      type: :invalid_checkout_session_state,
      safe_message: "Checkout session cannot initialize payment",
      retryable?: false,
      safe_metadata: %{status: status}
    }
  end

  defp amount_changed_error do
    %{
      type: :amount_changed,
      safe_message: "Order amount changed since payment initialization",
      retryable?: false,
      safe_metadata: %{}
    }
  end

  defp log_safe_start(order, attempt, context) do
    Logger.info(
      "paystack_initialize_started",
      Correlation.operational_metadata(%{
        correlation_id: context.correlation_id,
        order_public_reference: order.public_reference,
        payment_attempt_id: attempt.id,
        provider: "paystack",
        operation: "paystack_initialize"
      })
    )
  end
end
