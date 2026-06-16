defmodule FastCheck.Sales.StateTransition do
  @moduledoc """
  Append-only Sales state transition audit log.

  VS-05 adds `record_transition` for durable checkout and order lifecycle audit.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Changeset

  postgres do
    table("sales_state_transitions")
    repo(FastCheck.Repo)
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

    read :list_for_entity do
      argument :entity_type, :string do
        allow_nil?(false)
      end

      argument :entity_id, :string do
        allow_nil?(false)
      end

      filter(expr(entity_type == ^arg(:entity_type) and entity_id == ^arg(:entity_id)))
    end

    create :record_transition do
      accept([
        :entity_type,
        :entity_id,
        :from_state,
        :to_state,
        :reason,
        :actor_type,
        :actor_id,
        :metadata,
        :correlation_id,
        :request_id,
        :idempotency_key,
        :source
      ])

      validate(present([:entity_type, :entity_id, :to_state, :actor_type]))

      validate(fn changeset, _context ->
        actor_type = Changeset.get_attribute(changeset, :actor_type)
        reason = Changeset.get_attribute(changeset, :reason)
        source = Changeset.get_attribute(changeset, :source)

        manual_transition? =
          is_binary(source) and
            (String.ends_with?(source, ".cancelled") or
               String.ends_with?(source, ".manual_review"))

        if actor_type in ["admin", "operator"] and manual_transition? and
             (is_nil(reason) or reason == "") do
          {:error, field: :reason, message: "required for manual transitions"}
        else
          :ok
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
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]})
    end

    policy action(:record_transition) do
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system, :admin]})
    end
  end

  field_policies do
    private_fields(:include)

    field_policy :* do
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]})
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :entity_type, :string do
      allow_nil?(false)
    end

    attribute :entity_id, :string do
      allow_nil?(false)
    end

    attribute(:from_state, :string)

    attribute :to_state, :string do
      allow_nil?(false)
    end

    attribute(:reason, :string)

    attribute :actor_type, :string do
      allow_nil?(false)
    end

    attribute(:actor_id, :string)

    attribute :metadata, :map do
      allow_nil?(false)
      default(%{})
    end

    attribute(:correlation_id, :string)
    attribute(:request_id, :string)
    attribute(:idempotency_key, :string)
    attribute(:source, :string)

    create_timestamp(:inserted_at)
  end
end
