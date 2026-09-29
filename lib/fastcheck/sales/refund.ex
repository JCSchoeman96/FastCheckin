defmodule FastCheck.Sales.Refund do
  @moduledoc """
  Durable record of an admin-attested Paystack full refund.

  Paystack performs the refund outside FastCheck. This resource stores the
  provider evidence and exposes only named lifecycle transitions.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Query

  alias Ash.Changeset
  alias FastCheck.Repo
  alias FastCheck.Sales.StateTransitionSupport
  alias FastCheckWeb.Plugs.BrowserAuth

  postgres do
    table("sales_refunds")
    repo(FastCheck.Repo)

    identity_index_names(
      unique_order: "sales_refunds_order_uidx",
      unique_payment_attempt: "sales_refunds_payment_attempt_uidx",
      unique_provider_reference: "sales_refunds_provider_reference_uidx"
    )
  end

  actions do
    defaults([:read])

    read :get_by_id do
      get?(true)

      argument :id, :integer do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id)))
    end

    read :get_by_order_id do
      get?(true)

      argument :sales_order_id, :integer do
        allow_nil?(false)
      end

      filter(expr(sales_order_id == ^arg(:sales_order_id)))
    end

    create :record_full_refund_evidence do
      argument :admin_password, :string do
        allow_nil?(false)
      end

      accept([
        :sales_order_id,
        :payment_attempt_id,
        :provider_refund_reference,
        :provider_refunded_at,
        :amount_cents,
        :currency,
        :reason
      ])

      change(set_attribute(:provider, "paystack"))
      change(set_attribute(:provider_status, "processed"))
      change(set_attribute(:status, "evidence_recorded"))
      change(&set_recorded_by/2)

      validate(
        present([:provider_refund_reference, :provider_refunded_at, :recorded_by, :reason])
      )

      validate(&validate_evidence_authority/2)
      change(&record_create_transition/2)
    end

    update :mark_revocation_complete do
      require_atomic?(false)
      accept([])
      argument(:reason, :string)

      change(fn changeset, context ->
        if zero_issued_ticket_issues?(changeset) do
          transition_status(
            changeset,
            context,
            "revocation_complete",
            allowed_from: ["evidence_recorded"],
            reason: Changeset.get_argument(changeset, :reason),
            extra_attrs: %{revocation_completed_at: utc_now()}
          )
        else
          Changeset.add_error(changeset,
            field: :status,
            message: "all issued tickets must be revoked before refund finalization"
          )
        end
      end)
    end

    update :mark_revocation_manual_review do
      require_atomic?(false)
      accept([])

      argument :reason, :string do
        allow_nil?(false)
      end

      change(fn changeset, context ->
        reason = Changeset.get_argument(changeset, :reason)

        transition_status(changeset, context, "revocation_manual_review",
          allowed_from: ["evidence_recorded", "revocation_complete"],
          reason: reason,
          extra_attrs: %{manual_review_reason: reason}
        )
      end)
    end

    update :retry_refund_revocation do
      require_atomic?(false)
      accept([])

      argument :reason, :string do
        allow_nil?(false)
      end

      change(fn changeset, context ->
        reason = Changeset.get_argument(changeset, :reason)

        transition_status(changeset, context, "evidence_recorded",
          allowed_from: ["revocation_manual_review"],
          reason: reason,
          extra_attrs: %{manual_review_reason: nil}
        )
      end)
    end

    update :mark_inventory_pending do
      require_atomic?(false)
      accept([])
      argument(:reason, :string)

      change(fn changeset, context ->
        if Changeset.get_data(changeset, :revocation_completed_at) &&
             zero_issued_ticket_issues?(changeset) do
          transition_status(
            changeset,
            context,
            "inventory_pending",
            allowed_from: ["revocation_complete", "inventory_pending"],
            reason: Changeset.get_argument(changeset, :reason)
          )
        else
          Changeset.add_error(changeset,
            field: :status,
            message: "completed revocation is required before inventory resolution"
          )
        end
      end)
    end

    update :complete_released_unconsumed do
      require_atomic?(false)
      accept([])
      argument(:reason, :string)

      change(fn changeset, context ->
        complete_inventory(
          changeset,
          context,
          "released_unconsumed",
          Changeset.get_argument(changeset, :reason)
        )
      end)
    end

    update :complete_retained_consumed do
      require_atomic?(false)
      accept([])
      argument(:reason, :string)

      change(fn changeset, context ->
        complete_inventory(
          changeset,
          context,
          "retained_consumed",
          Changeset.get_argument(changeset, :reason)
        )
      end)
    end

    update :mark_inventory_manual_review do
      require_atomic?(false)
      accept([])

      argument :reason, :string do
        allow_nil?(false)
      end

      change(fn changeset, context ->
        reason = Changeset.get_argument(changeset, :reason)

        transition_status(changeset, context, "inventory_manual_review",
          allowed_from: ["inventory_pending", "inventory_manual_review"],
          reason: reason,
          extra_attrs: %{manual_review_reason: reason}
        )
      end)
    end

    update :retry_refund_inventory do
      require_atomic?(false)
      accept([])

      argument :reason, :string do
        allow_nil?(false)
      end

      change(fn changeset, context ->
        reason = Changeset.get_argument(changeset, :reason)

        transition_status(changeset, context, "inventory_pending",
          allowed_from: ["inventory_manual_review"],
          reason: reason,
          extra_attrs: %{manual_review_reason: nil}
        )
      end)
    end
  end

  policies do
    bypass {FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]} do
      authorize_if(always())
    end

    policy action_type(:read) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:admin]})
    end

    policy action_type(:read) do
      authorize_if({FastCheck.Sales.PolicyChecks.EventAllowed, relationship_path: [:order]})
    end

    policy action([:record_full_refund_evidence]) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:admin]})
    end

    policy action([
             :mark_revocation_complete,
             :mark_revocation_manual_review,
             :retry_refund_revocation,
             :mark_inventory_pending,
             :mark_inventory_manual_review,
             :retry_refund_inventory
           ]) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:admin]})
    end

    policy action([:complete_released_unconsumed, :complete_retained_consumed]) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]})
    end

    policy action_type(:update) do
      authorize_if({FastCheck.Sales.PolicyChecks.EventAllowed, relationship_path: [:order]})
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :sales_order_id, :integer do
      allow_nil?(false)
    end

    attribute :payment_attempt_id, :integer do
      allow_nil?(false)
    end

    attribute :provider, :string do
      allow_nil?(false)
      default("paystack")
    end

    attribute :provider_status, :string do
      allow_nil?(false)
      default("processed")
    end

    attribute :provider_refund_reference, :string do
      allow_nil?(false)
    end

    attribute :provider_refunded_at, :utc_datetime do
      allow_nil?(false)
    end

    attribute :amount_cents, :integer do
      allow_nil?(false)
    end

    attribute :currency, :string do
      allow_nil?(false)
    end

    attribute :status, :string do
      allow_nil?(false)
      default("evidence_recorded")
    end

    attribute(:inventory_resolution_status, :string)

    attribute :recorded_by, :string do
      allow_nil?(false)
    end

    attribute :reason, :string do
      allow_nil?(false)
    end

    attribute(:revocation_completed_at, :utc_datetime)
    attribute(:completed_at, :utc_datetime)
    attribute(:manual_review_reason, :string)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :order, FastCheck.Sales.Order do
      source_attribute(:sales_order_id)
      attribute_type(:integer)
      allow_nil?(false)
    end

    belongs_to :payment_attempt, FastCheck.Sales.PaymentAttempt do
      source_attribute(:payment_attempt_id)
      attribute_type(:integer)
      allow_nil?(false)
    end
  end

  identities do
    identity(:unique_order, [:sales_order_id])
    identity(:unique_payment_attempt, [:payment_attempt_id])
    identity(:unique_provider_reference, [:provider_refund_reference])
  end

  defp validate_evidence_authority(changeset, context) do
    order_id = Changeset.get_attribute(changeset, :sales_order_id)
    payment_attempt_id = Changeset.get_attribute(changeset, :payment_attempt_id)
    provider = Changeset.get_attribute(changeset, :provider)
    provider_status = Changeset.get_attribute(changeset, :provider_status)
    provider_reference = Changeset.get_attribute(changeset, :provider_refund_reference)
    refunded_at = Changeset.get_attribute(changeset, :provider_refunded_at)
    amount_cents = Changeset.get_attribute(changeset, :amount_cents)
    currency = Changeset.get_attribute(changeset, :currency)
    recorded_by = Changeset.get_attribute(changeset, :recorded_by)
    reason = Changeset.get_attribute(changeset, :reason)
    actor = Map.get(context, :actor, %{})
    admin_password = Changeset.get_argument(changeset, :admin_password)

    cond do
      provider != "paystack" or provider_status != "processed" ->
        {:error, field: :provider_status, message: "must be processed Paystack refund evidence"}

      not nonblank?(provider_reference) or is_nil(refunded_at) or not nonblank?(recorded_by) or
          not nonblank?(reason) ->
        {:error,
         field: :provider_refund_reference, message: "complete refund evidence is required"}

      not is_integer(amount_cents) or amount_cents <= 0 ->
        {:error, field: :amount_cents, message: "must be a positive full-refund amount"}

      not valid_payment_authority?(
        order_id,
        payment_attempt_id,
        amount_cents,
        currency,
        actor,
        admin_password
      ) ->
        {:error, field: :payment_attempt_id, message: "must match the unique verified payment"}

      true ->
        :ok
    end
  end

  defp valid_payment_authority?(
         order_id,
         payment_attempt_id,
         amount_cents,
         currency,
         actor,
         admin_password
       )
       when is_integer(order_id) and is_integer(payment_attempt_id) do
    case Repo.query(
           """
           SELECT o.total_amount_cents, o.currency, o.status, o.event_id,
                  p.sales_order_id, p.provider, p.status, p.amount_cents, p.currency,
                  (SELECT count(*)
                   FROM sales_payment_attempts candidates
                   WHERE candidates.sales_order_id = o.id
                     AND candidates.status = 'verified_success'
                  )
           FROM sales_orders o
           INNER JOIN sales_payment_attempts p ON p.id = $2
           WHERE o.id = $1
           """,
           [order_id, payment_attempt_id]
         ) do
      {:ok,
       %{
         rows: [
           [
             ^amount_cents,
             ^currency,
             order_status,
             event_id,
             ^order_id,
             "paystack",
             "verified_success",
             ^amount_cents,
             ^currency,
             1
           ]
         ]
       }} ->
        valid_admin_event_actor?(actor, event_id, admin_password) and
          order_status in [
            "paid_verified",
            "fulfillment_queued",
            "partially_issued",
            "issuance_retry_queued",
            "ticket_issued",
            "manual_review",
            "manual_review_held"
          ]

      _ ->
        false
    end
  end

  defp valid_payment_authority?(
         _order_id,
         _payment_attempt_id,
         _amount_cents,
         _currency,
         _actor,
         _admin_password
       ),
       do: false

  defp valid_admin_event_actor?(actor, event_id, admin_password) do
    actor_type = Map.get(actor, :actor_type) || Map.get(actor, "actor_type")

    allowed_event_ids =
      Map.get(actor, :allowed_event_ids) || Map.get(actor, "allowed_event_ids")

    actor_type in [:admin, "admin"] and is_list(allowed_event_ids) and
      event_id in allowed_event_ids and BrowserAuth.valid_admin_password?(admin_password)
  end

  defp zero_issued_ticket_issues?(changeset) do
    case Changeset.get_data(changeset, :sales_order_id) do
      order_id when is_integer(order_id) ->
        Repo.one!(
          from issue in "sales_ticket_issues",
            where: issue.sales_order_id == ^order_id and issue.status == "issued",
            select: count(issue.id)
        ) == 0

      _ ->
        false
    end
  end

  defp complete_inventory(changeset, context, resolution, reason) do
    from_state = Changeset.get_data(changeset, :status)
    existing_resolution = Changeset.get_data(changeset, :inventory_resolution_status)

    cond do
      from_state == "completed" and existing_resolution == resolution ->
        if valid_inventory_completion_authority?(changeset, resolution),
          do: changeset,
          else: add_inventory_authority_error(changeset)

      from_state == "inventory_pending" ->
        if valid_inventory_completion_authority?(changeset, resolution) do
          transition_status(
            changeset,
            context,
            "completed",
            allowed_from: ["inventory_pending"],
            reason: reason,
            extra_attrs: %{
              inventory_resolution_status: resolution,
              completed_at: utc_now(),
              manual_review_reason: nil
            }
          )
        else
          add_inventory_authority_error(changeset)
        end

      true ->
        Changeset.add_error(changeset,
          field: :status,
          message: "inventory can only complete from inventory_pending"
        )
    end
  end

  defp add_inventory_authority_error(changeset) do
    Changeset.add_error(changeset,
      field: :status,
      message:
        "refund financial and revocation authority must be complete before inventory resolution"
    )
  end

  defp valid_inventory_completion_authority?(changeset, resolution) do
    refund_id = Changeset.get_data(changeset, :id)

    case Repo.query(
           """
           SELECT EXISTS (
             SELECT 1
             FROM sales_refunds r
             INNER JOIN sales_orders o ON o.id = r.sales_order_id
             INNER JOIN sales_payment_attempts p
               ON p.id = r.payment_attempt_id AND p.sales_order_id = o.id
             WHERE r.id = $1
               AND r.provider = 'paystack'
               AND r.provider_status = 'processed'
               AND r.provider_refund_reference IS NOT NULL
               AND btrim(r.provider_refund_reference) <> ''
               AND r.provider_refunded_at IS NOT NULL
               AND r.recorded_by IS NOT NULL
               AND btrim(r.recorded_by) <> ''
               AND r.reason IS NOT NULL
               AND btrim(r.reason) <> ''
               AND r.status IN ('inventory_pending', 'completed')
               AND ((r.status = 'inventory_pending' AND r.inventory_resolution_status IS NULL)
                 OR (r.status = 'completed' AND r.inventory_resolution_status = $2))
               AND r.amount_cents = o.total_amount_cents
               AND r.currency = o.currency
               AND r.revocation_completed_at IS NOT NULL
               AND p.provider = 'paystack'
               AND p.status = 'refunded'
               AND p.amount_cents = o.total_amount_cents
               AND p.currency = o.currency
               AND (SELECT count(*)
                    FROM sales_payment_attempts candidates
                    WHERE candidates.sales_order_id = o.id
                      AND candidates.status IN ('verified_success', 'refunded')) = 1
               AND (SELECT count(*)
                    FROM sales_order_lines lines
                    WHERE lines.sales_order_id = o.id) = 1
               AND EXISTS (
                 SELECT 1
                 FROM sales_order_lines line
                 WHERE line.sales_order_id = o.id
                   AND line.quantity > 0
                   AND line.total_amount_cents = o.total_amount_cents
                   AND line.currency = o.currency
               )
               AND o.status = 'refunded'
               AND NOT EXISTS (
                 SELECT 1 FROM sales_ticket_issues issues
                 WHERE issues.sales_order_id = o.id AND issues.status = 'issued'
               )
           )
           """,
           [refund_id, resolution]
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp transition_status(changeset, context, to_status, opts) do
    from_state = Changeset.get_data(changeset, :status)
    allowed_from = Keyword.get(opts, :allowed_from)
    reason = Keyword.get(opts, :reason)
    extra_attrs = Keyword.get(opts, :extra_attrs, %{})

    changeset =
      if from_state in allowed_from do
        changeset
      else
        Changeset.add_error(changeset,
          field: :status,
          message: "invalid refund transition from #{from_state}"
        )
      end

    if changeset.valid? do
      changeset =
        changeset
        |> Changeset.force_change_attribute(:status, to_status)
        |> then(fn cs ->
          Enum.reduce(extra_attrs, cs, fn {field, value}, current ->
            Changeset.force_change_attribute(current, field, value)
          end)
        end)

      Changeset.after_action(changeset, fn _changeset, record ->
        case StateTransitionSupport.record!(
               %{
                 entity_type: "Refund",
                 entity_id: Integer.to_string(record.id),
                 from_state: from_state,
                 to_state: record.status,
                 reason: reason || record.manual_review_reason,
                 metadata: %{},
                 correlation_id: transition_correlation_id(context),
                 idempotency_key: nil,
                 source: "refund.#{record.status}"
               },
               context
             ) do
          {:ok, _transition} -> {:ok, record}
          {:error, error} -> {:error, error}
        end
      end)
    else
      changeset
    end
  end

  defp record_create_transition(changeset, context) do
    Changeset.after_action(changeset, fn _changeset, record ->
      case StateTransitionSupport.record!(
             %{
               entity_type: "Refund",
               entity_id: Integer.to_string(record.id),
               from_state: nil,
               to_state: record.status,
               reason: record.reason,
               metadata: %{provider: record.provider, amount_cents: record.amount_cents},
               correlation_id: transition_correlation_id(context),
               idempotency_key: nil,
               source: "refund.evidence_recorded"
             },
             context
           ) do
        {:ok, _transition} -> {:ok, record}
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp set_recorded_by(changeset, context) do
    actor = Map.get(context, :actor, %{})

    recorded_by =
      Map.get(actor, :actor_id) || Map.get(actor, :id) || Map.get(actor, :username) ||
        Map.get(actor, "actor_id") || Map.get(actor, "id") || Map.get(actor, "username")

    if nonblank?(recorded_by) do
      Changeset.force_change_attribute(changeset, :recorded_by, to_string(recorded_by))
    else
      Changeset.add_error(changeset,
        field: :recorded_by,
        message: "admin identity is required"
      )
    end
  end

  defp transition_correlation_id(context) do
    actor = Map.get(context, :actor, %{})
    Map.get(context, :correlation_id) || Map.get(actor, :correlation_id)
  end

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
