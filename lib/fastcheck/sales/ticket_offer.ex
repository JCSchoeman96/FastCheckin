defmodule FastCheck.Sales.TicketOffer do
  @moduledoc """
  Durable ticket offer configuration skeleton for FastCheck Sales.

  This resource stores configured offer facts only. Live inventory remains owned
  by future Redis/ReservationLedger slices.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("sales_ticket_offers")
    repo(FastCheck.Repo)

    identity_index_names(unique_active_name_per_event: "sales_ticket_offers_active_name_uidx")
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
      authorize_if(FastCheck.Sales.PolicyChecks.EventAllowed)
    end
  end

  field_policies do
    private_fields(:include)

    field_policy :* do
      authorize_if(
        {FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system, :admin, :operator]}
      )
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :event_id, :integer do
      allow_nil?(false)
    end

    attribute :name, :string do
      allow_nil?(false)
    end

    attribute :ticket_type, :string do
      allow_nil?(false)
    end

    attribute :price_cents, :integer do
      allow_nil?(false)
    end

    attribute :currency, :string do
      allow_nil?(false)
    end

    attribute :configured_quantity_available, :integer do
      allow_nil?(false)
    end

    attribute :initial_quantity, :integer do
      allow_nil?(false)
    end

    attribute :max_per_order, :integer do
      allow_nil?(false)
    end

    attribute :sales_enabled, :boolean do
      allow_nil?(false)
      default(false)
    end

    attribute :sales_channel, :string do
      allow_nil?(false)
    end

    attribute :starts_at, :utc_datetime do
      allow_nil?(false)
    end

    attribute :ends_at, :utc_datetime do
      allow_nil?(false)
    end

    attribute :lock_version, :integer do
      allow_nil?(false)
      default(1)
    end

    attribute(:archived_at, :utc_datetime)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many :order_lines, FastCheck.Sales.OrderLine do
      destination_attribute(:ticket_offer_id)
    end
  end

  identities do
    identity :unique_active_name_per_event, [:event_id, :name] do
      where(expr(is_nil(archived_at)))
    end
  end
end
