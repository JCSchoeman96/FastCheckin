defmodule FastCheck.Sales.StateTransition do
  @moduledoc """
  Append-only Sales state transition audit skeleton.

  VS-01B defines the audit row shape only. Transition recording helpers and
  workflow enforcement belong to later slices.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer

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
