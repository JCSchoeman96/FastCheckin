defmodule FastCheck.Sales.Conversation do
  @moduledoc """
  Durable WhatsApp conversation checkpoint skeleton.

  VS-01E stores recoverable conversation checkpoint shape only. Meta webhooks,
  WhatsApp sending, Redis session/rate-limit behavior, checkout creation,
  payment handling, ticket delivery, and menu workflow actions are deferred.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("sales_conversations")
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

    read(:list_recent)

    read :list_needing_human do
      filter(expr(needs_human == true))
    end

    read :list_by_phone do
      argument :phone_e164, :string do
        allow_nil?(false)
      end

      filter(expr(phone_e164 == ^arg(:phone_e164)))
    end
  end

  policies do
    policy action_type(:read) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]})
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

    attribute :phone_e164, :string do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute :wa_id, :string do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute(:session_key, :string, sensitive?: true)
    attribute(:rate_limit_key, :string, sensitive?: true)

    attribute :preferred_language, :string do
      allow_nil?(false)
      default("af")
    end

    attribute(:locale, :string)

    attribute :state, :string do
      allow_nil?(false)
      default("new")
    end

    attribute :state_data, :map do
      allow_nil?(false)
      default(%{})
      sensitive?(true)
    end

    attribute(:last_inbound_message_id, :string, sensitive?: true)
    attribute(:last_outbound_message_id, :string, sensitive?: true)
    attribute(:last_message_at, :utc_datetime)
    attribute(:expires_at, :utc_datetime)

    attribute :needs_human, :boolean do
      allow_nil?(false)
      default(false)
    end

    attribute(:handoff_reason, :string, sensitive?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many :orders, FastCheck.Sales.Order do
      destination_attribute(:sales_conversation_id)
    end
  end
end
