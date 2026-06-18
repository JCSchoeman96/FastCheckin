defmodule FastCheck.Sales.PaymentEvent do
  @moduledoc """
  Durable raw payment provider event for FastCheck Sales.

  VS-07A adds webhook ingestion storage. VS-07B adds processing-status workflow
  actions for verification handoff.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Changeset

  postgres do
    table("sales_payment_events")
    repo(FastCheck.Repo)

    identity_index_names(
      unique_provider_event_id: "sales_payment_events_provider_event_id_uidx",
      unique_provider_payload_hash: "sales_payment_events_provider_payload_hash_uidx"
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

    read :get_by_provider_event_id do
      get?(true)

      argument :provider, :string do
        allow_nil?(false)
      end

      argument :provider_event_id, :string do
        allow_nil?(false)
      end

      filter(expr(provider == ^arg(:provider) and provider_event_id == ^arg(:provider_event_id)))
    end

    read :get_by_provider_payload_hash do
      get?(true)

      argument :provider, :string do
        allow_nil?(false)
      end

      argument :payload_hash, :string do
        allow_nil?(false)
      end

      filter(
        expr(
          provider == ^arg(:provider) and is_nil(provider_event_id) and
            payload_hash == ^arg(:payload_hash)
        )
      )
    end

    create :store_webhook_event do
      accept([
        :provider,
        :provider_event_id,
        :provider_reference,
        :event_type,
        :signature_valid,
        :payload_hash,
        :raw_payload,
        :received_at,
        :processing_status,
        :processing_attempt_count
      ])

      transaction?(false)
    end

    update :mark_processing_started do
      require_atomic?(false)
      accept([])

      change(fn changeset, context ->
        from_state = Changeset.get_data(changeset, :processing_status)

        cond do
          from_state == "processing_started" ->
            changeset

          from_state in ["stored", "failed"] ->
            count = Changeset.get_data(changeset, :processing_attempt_count) || 0

            transition_processing_status(
              changeset,
              context,
              "processing_started",
              extra_attrs: %{processing_attempt_count: count + 1}
            )

          true ->
            Changeset.add_error(changeset,
              field: :processing_status,
              message: "invalid transition from #{from_state}"
            )
        end
      end)

      transaction?(false)
    end

    update :mark_processed do
      require_atomic?(false)
      accept([])

      change(fn changeset, context ->
        from_state = Changeset.get_data(changeset, :processing_status)

        if from_state == "processed" do
          changeset
        else
          transition_processing_status(
            changeset,
            context,
            "processed",
            allowed_from: ["processing_started"],
            extra_attrs: %{
              processed_at: DateTime.utc_now() |> DateTime.truncate(:second)
            }
          )
        end
      end)

      transaction?(false)
    end

    update :mark_unmatched do
      require_atomic?(false)
      accept([:last_processing_error])

      change(fn changeset, context ->
        from_state = Changeset.get_data(changeset, :processing_status)

        if from_state == "unmatched" do
          changeset
        else
          transition_processing_status(
            changeset,
            context,
            "unmatched",
            allowed_from: ["stored", "processing_started"],
            extra_attrs: %{
              last_processing_error_at: DateTime.utc_now() |> DateTime.truncate(:second)
            }
          )
        end
      end)

      transaction?(false)
    end

    update :mark_failed do
      require_atomic?(false)
      accept([:last_processing_error])

      change(fn changeset, context ->
        from_state = Changeset.get_data(changeset, :processing_status)

        if from_state == "failed" do
          changeset
        else
          transition_processing_status(
            changeset,
            context,
            "failed",
            allowed_from: ["processing_started"],
            extra_attrs: %{
              last_processing_error_at: DateTime.utc_now() |> DateTime.truncate(:second)
            }
          )
        end
      end)

      transaction?(false)
    end
  end

  policies do
    bypass {FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]} do
      authorize_if(always())
    end

    policy action(:store_webhook_event) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]})
    end

    policy action_type(:read) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:admin, :operator]})
    end
  end

  field_policies do
    private_fields(:include)

    field_policy [:raw_payload, :last_processing_error] do
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]})
    end

    field_policy :* do
      authorize_if(
        {FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system, :admin, :operator]}
      )
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :provider, :string do
      allow_nil?(false)
    end

    attribute(:provider_event_id, :string)
    attribute(:provider_reference, :string)

    attribute :event_type, :string do
      allow_nil?(false)
    end

    attribute(:signature_valid, :boolean)
    attribute(:payload_hash, :string)
    attribute(:raw_payload, :map, sensitive?: true)

    attribute(:received_at, :utc_datetime)
    attribute(:processed_at, :utc_datetime)

    attribute :processing_status, :string do
      allow_nil?(false)
    end

    attribute :processing_attempt_count, :integer do
      allow_nil?(false)
      default(0)
    end

    attribute(:last_processing_error, :string)
    attribute(:last_processing_error_at, :utc_datetime)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity :unique_provider_event_id, [:provider, :provider_event_id] do
      where(expr(not is_nil(provider_event_id)))
    end

    identity :unique_provider_payload_hash, [:provider, :payload_hash] do
      where(expr(is_nil(provider_event_id)))
    end
  end

  defp transition_processing_status(changeset, _context, to_status, opts) do
    from_state = Changeset.get_data(changeset, :processing_status)
    allowed_from = Keyword.get(opts, :allowed_from)
    extra_attrs = Keyword.get(opts, :extra_attrs, %{})

    changeset =
      if allowed_from && from_state not in allowed_from do
        Changeset.add_error(changeset,
          field: :processing_status,
          message: "invalid transition from #{from_state}"
        )
      else
        changeset
      end

    if changeset.valid? do
      changeset
      |> Changeset.force_change_attribute(:processing_status, to_status)
      |> then(fn cs ->
        Enum.reduce(
          extra_attrs,
          cs,
          &Changeset.force_change_attribute(&2, elem(&1, 0), elem(&1, 1))
        )
      end)
    else
      changeset
    end
  end
end
