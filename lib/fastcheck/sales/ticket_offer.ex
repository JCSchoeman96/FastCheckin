defmodule FastCheck.Sales.TicketOffer do
  @moduledoc """
  Durable ticket offer configuration for FastCheck Sales.

  This resource owns admin-managed offer setup only. Live inventory remains owned
  by Redis/ReservationLedger slices.
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

    create :create_offer do
      primary?(true)

      accept([
        :event_id,
        :name,
        :ticket_type,
        :price_cents,
        :currency,
        :configured_quantity_available,
        :initial_quantity,
        :max_per_order,
        :sales_enabled,
        :sales_channel,
        :starts_at,
        :ends_at,
        :archived_at
      ])

      validate(present([:event_id, :name, :ticket_type, :sales_channel]))
      validate(compare(:price_cents, greater_than_or_equal_to: 0))
      validate(compare(:configured_quantity_available, greater_than_or_equal_to: 0))
      validate(compare(:initial_quantity, greater_than_or_equal_to: 0))
      validate(compare(:max_per_order, greater_than_or_equal_to: 1))
      validate(compare(:max_per_order, less_than_or_equal_to: :configured_quantity_available))
      validate(match(:currency, ~r/^[A-Z]{3}$/))
      validate(one_of(:sales_channel, ["whatsapp", "admin", "web", "all", "internal"]))
      change(&attach_cache_invalidation/2)
    end

    update :update_offer do
      require_atomic?(false)

      accept([
        :name,
        :ticket_type,
        :price_cents,
        :currency,
        :configured_quantity_available,
        :initial_quantity,
        :max_per_order,
        :sales_channel,
        :starts_at,
        :ends_at,
        :archived_at
      ])

      change(optimistic_lock(:lock_version))
      change(&attach_cache_invalidation/2)

      validate(compare(:price_cents, greater_than_or_equal_to: 0))
      validate(compare(:configured_quantity_available, greater_than_or_equal_to: 0))
      validate(compare(:initial_quantity, greater_than_or_equal_to: 0))
      validate(compare(:max_per_order, greater_than_or_equal_to: 1))
      validate(compare(:max_per_order, less_than_or_equal_to: :configured_quantity_available))
      validate(match(:currency, ~r/^[A-Z]{3}$/))
      validate(one_of(:sales_channel, ["whatsapp", "admin", "web", "all", "internal"]))
    end

    update :enable_sales do
      require_atomic?(false)

      change(set_attribute(:sales_enabled, true))
      change(optimistic_lock(:lock_version))
      change(&attach_cache_invalidation/2)
    end

    update :disable_sales do
      require_atomic?(false)

      change(set_attribute(:sales_enabled, false))
      change(optimistic_lock(:lock_version))
      change(&attach_cache_invalidation/2)
    end

    read :get_by_id do
      get?(true)

      argument :id, :integer do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id)))
    end

    read :list_active_for_event do
      argument :event_id, :integer do
        allow_nil?(false)
      end

      argument :sales_channel, :string do
        allow_nil?(false)
      end

      argument :as_of, :utc_datetime do
        allow_nil?(false)
      end

      filter(
        expr(
          event_id == ^arg(:event_id) and sales_enabled == true and is_nil(archived_at) and
            (is_nil(starts_at) or starts_at <= ^arg(:as_of)) and
            (is_nil(ends_at) or ends_at > ^arg(:as_of)) and
            (sales_channel == "all" or sales_channel == ^arg(:sales_channel))
        )
      )
    end

    read :get_available_for_checkout do
      get?(true)

      argument :id, :integer do
        allow_nil?(false)
      end

      argument :event_id, :integer do
        allow_nil?(false)
      end

      argument :sales_channel, :string do
        allow_nil?(false)
      end

      argument :as_of, :utc_datetime do
        allow_nil?(false)
      end

      filter(
        expr(
          id == ^arg(:id) and event_id == ^arg(:event_id) and sales_enabled == true and
            is_nil(archived_at) and (is_nil(starts_at) or starts_at <= ^arg(:as_of)) and
            (is_nil(ends_at) or ends_at > ^arg(:as_of)) and
            (sales_channel == "all" or sales_channel == ^arg(:sales_channel))
        )
      )
    end
  end

  policies do
    bypass {FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]} do
      authorize_if(always())
    end

    policy action([:read, :get_by_id]) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:admin, :operator]})
    end

    policy action([:list_active_for_event, :get_available_for_checkout]) do
      access_type(:strict)

      authorize_if(
        {FastCheck.Sales.PolicyChecks.ActorTypeIn,
         actor_types: [:admin, :operator, :customer_session]}
      )
    end

    policy action([:create_offer, :update_offer, :enable_sales, :disable_sales]) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:admin]})
    end

    policy action([:read, :get_by_id]) do
      authorize_if(FastCheck.Sales.PolicyChecks.EventAllowed)
    end

    policy action([:create_offer, :update_offer, :enable_sales, :disable_sales]) do
      authorize_if({FastCheck.Sales.PolicyChecks.EventAllowed, actor_types: [:admin]})
    end

    policy action([:list_active_for_event, :get_available_for_checkout]) do
      authorize_if(
        {FastCheck.Sales.PolicyChecks.EventAllowed,
         actor_types: [:admin, :operator, :customer_session]}
      )
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
      allow_nil?(true)
    end

    attribute :ends_at, :utc_datetime do
      allow_nil?(true)
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

  defp attach_cache_invalidation(changeset, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      FastCheck.Sales.Offers.CacheInvalidation.invalidate_event_offers(record.event_id)
      {:ok, record}
    end)
  end
end
