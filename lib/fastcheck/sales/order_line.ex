defmodule FastCheck.Sales.OrderLine do
  @moduledoc """
  Durable Sales order line price snapshot skeleton.

  Historical order-line amounts must not be recalculated from ticket offers.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("sales_order_lines")
    repo(FastCheck.Repo)

    identity_index_names(unique_line_number_per_order: "sales_order_lines_order_line_number_uidx")
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

    read :list_for_order do
      argument :sales_order_id, :integer do
        allow_nil?(false)
      end

      filter(expr(sales_order_id == ^arg(:sales_order_id)))
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

    attribute :line_number, :integer do
      allow_nil?(false)
    end

    attribute :ticket_type, :string do
      allow_nil?(false)
    end

    attribute :offer_name_snapshot, :string do
      allow_nil?(false)
    end

    attribute :event_name_snapshot, :string do
      allow_nil?(false)
    end

    attribute :quantity, :integer do
      allow_nil?(false)
    end

    attribute :unit_amount_cents, :integer do
      allow_nil?(false)
    end

    attribute :total_amount_cents, :integer do
      allow_nil?(false)
    end

    attribute :currency, :string do
      allow_nil?(false)
    end

    attribute :metadata, :map do
      allow_nil?(false)
      default(%{})
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

    belongs_to :ticket_offer, FastCheck.Sales.TicketOffer do
      source_attribute(:ticket_offer_id)
      attribute_type(:integer)
      allow_nil?(false)
    end

    has_many :ticket_issues, FastCheck.Sales.TicketIssue do
      destination_attribute(:sales_order_line_id)
    end
  end

  identities do
    identity(:unique_line_number_per_order, [:sales_order_id, :line_number])
  end
end
