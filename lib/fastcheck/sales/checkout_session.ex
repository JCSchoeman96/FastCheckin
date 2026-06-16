defmodule FastCheck.Sales.CheckoutSession do
  @moduledoc """
  Durable checkout session for FastCheck Sales.

  VS-05 adds checkout session workflow actions and Redis hold metadata persistence.
  Inventory mutation remains in ReservationLedger; this resource stores durable hold facts only.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Changeset
  alias FastCheck.Sales.StateTransitionSupport

  postgres do
    table("sales_checkout_sessions")
    repo(FastCheck.Repo)

    identity_index_names(
      unique_order: "sales_checkout_sessions_sales_order_id_uidx",
      unique_redis_hold_key: "sales_checkout_sessions_redis_hold_key_uidx"
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

    create :create_session do
      accept([:sales_order_id])
      change(set_attribute(:status, "created"))
      change(&record_create_transition/2)
    end

    update :attach_inventory_hold do
      require_atomic?(false)

      accept([:redis_hold_key, :hold_token, :hold_quantity, :expires_at])
      validate(fn changeset, context -> status_in(["created"]).(changeset, context) end)

      change(fn changeset, context ->
        from_state = Changeset.get_data(changeset, :status)

        changeset
        |> Changeset.force_change_attribute(:status, "hold_attached")
        |> Changeset.after_action(fn _cs, record ->
          StateTransitionSupport.record!(
            %{
              entity_type: "CheckoutSession",
              entity_id: Integer.to_string(record.id),
              from_state: from_state,
              to_state: record.status,
              metadata: session_transition_metadata(context, record),
              correlation_id: transition_correlation_id(context),
              source: "checkout_session.attach_inventory_hold"
            },
            context
          )

          {:ok, record}
        end)
      end)
    end

    update :mark_payment_link_sent do
      require_atomic?(false)
      accept([])

      change(
        &transition_status(&1, &2, "payment_link_sent",
          allowed_from: ["hold_attached"],
          timestamp_field: :payment_link_sent_at
        )
      )
    end

    update :expire_session do
      require_atomic?(false)
      accept([])

      change(
        &transition_status(&1, &2, "expired",
          allowed_from: ["created", "hold_attached", "payment_link_sent", "payment_started"],
          timestamp_field: :expired_at
        )
      )
    end

    update :release_session do
      require_atomic?(false)
      accept([])
      argument(:reason, :string)

      change(fn changeset, context ->
        reason = Changeset.get_argument(changeset, :reason)

        transition_status(
          changeset,
          context,
          "released",
          allowed_from: ["hold_attached", "payment_link_sent", "payment_started"],
          reason: reason,
          timestamp_field: :released_at
        )
      end)
    end

    update :mark_manual_review do
      require_atomic?(false)
      accept([:state_data])
      argument(:reason, :string)

      change(fn changeset, context ->
        reason = Changeset.get_argument(changeset, :reason)
        from_state = Changeset.get_data(changeset, :status)

        if from_state == "manual_review" do
          changeset
        else
          transition_status(
            changeset,
            context,
            "manual_review",
            allowed_from: nil,
            reason: reason
          )
        end
      end)
    end
  end

  policies do
    bypass {FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]} do
      authorize_if(always())
    end

    policy action_type(:read) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:admin, :operator]})
    end

    policy action_type(:read) do
      authorize_if({FastCheck.Sales.PolicyChecks.EventAllowed, relationship_path: [:order]})
    end

    policy action([:create_session, :release_session, :mark_manual_review]) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:admin]})
    end

    policy action([:create_session, :release_session, :mark_manual_review]) do
      authorize_if(
        {FastCheck.Sales.PolicyChecks.EventAllowed,
         relationship_path: [:order], actor_types: [:admin]}
      )
    end
  end

  field_policies do
    private_fields(:include)

    field_policy [:hold_token, :state_data] do
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system, :admin]})
    end

    field_policy :* do
      authorize_if(
        {FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system, :admin, :operator]}
      )
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :status, :string do
      allow_nil?(false)
    end

    attribute(:redis_hold_key, :string)
    attribute(:hold_token, :string, sensitive?: true)
    attribute(:hold_quantity, :integer)
    attribute(:payment_link_sent_at, :utc_datetime)
    attribute(:released_at, :utc_datetime)
    attribute(:expired_at, :utc_datetime)
    attribute(:last_seen_at, :utc_datetime)
    attribute(:expires_at, :utc_datetime)

    attribute :state_data, :map do
      allow_nil?(false)
      default(%{})
    end

    attribute :lock_version, :integer do
      allow_nil?(false)
      default(1)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :order, FastCheck.Sales.Order do
      source_attribute(:sales_order_id)
      attribute_type(:integer)
      allow_nil?(false)
    end
  end

  identities do
    identity(:unique_order, [:sales_order_id])

    identity :unique_redis_hold_key, [:redis_hold_key] do
      where(expr(not is_nil(redis_hold_key)))
    end
  end

  defp status_in(allowed) do
    fn changeset, _context ->
      status = Changeset.get_data(changeset, :status)

      if status in allowed do
        :ok
      else
        {:error, field: :status, message: "invalid transition from #{status}"}
      end
    end
  end

  defp record_create_transition(changeset, context) do
    Changeset.after_action(changeset, fn _changeset, record ->
      StateTransitionSupport.record!(
        %{
          entity_type: "CheckoutSession",
          entity_id: Integer.to_string(record.id),
          from_state: nil,
          to_state: "created",
          metadata: session_transition_metadata(context, record),
          correlation_id: transition_correlation_id(context),
          source: "checkout_session.create_session"
        },
        context
      )

      {:ok, record}
    end)
  end

  defp transition_status(changeset, context, to_status, opts) do
    from_state = Changeset.get_data(changeset, :status)
    allowed_from = Keyword.get(opts, :allowed_from)
    reason = Keyword.get(opts, :reason)
    timestamp_field = Keyword.get(opts, :timestamp_field)

    changeset =
      if allowed_from && from_state not in allowed_from do
        Changeset.add_error(changeset,
          field: :status,
          message: "invalid transition from #{from_state}"
        )
      else
        changeset
      end

    if changeset.valid? do
      changeset =
        changeset
        |> Changeset.force_change_attribute(:status, to_status)
        |> then(fn cs ->
          if timestamp_field do
            Changeset.force_change_attribute(
              cs,
              timestamp_field,
              DateTime.utc_now() |> DateTime.truncate(:second)
            )
          else
            cs
          end
        end)

      Changeset.after_action(changeset, fn _changeset, record ->
        case StateTransitionSupport.record!(
               %{
                 entity_type: "CheckoutSession",
                 entity_id: Integer.to_string(record.id),
                 from_state: from_state,
                 to_state: record.status,
                 reason: reason,
                 metadata: session_transition_metadata(context, record),
                 correlation_id: transition_correlation_id(context),
                 source: "checkout_session.#{record.status}"
               },
               context
             ) do
          {:ok, _} -> {:ok, record}
          {:error, error} -> {:error, error}
        end
      end)
    else
      changeset
    end
  end

  defp transition_correlation_id(context) do
    actor = Map.get(context, :actor, %{})
    Map.get(context, :correlation_id) || Map.get(actor, :correlation_id)
  end

  defp session_transition_metadata(context, record) do
    base =
      %{}
      |> maybe_put(:redis_hold_key, record.redis_hold_key)
      |> maybe_put(:source_channel, Map.get(context, :source_channel))

    context
    |> Map.get(:transition_metadata, %{})
    |> Map.merge(base)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
