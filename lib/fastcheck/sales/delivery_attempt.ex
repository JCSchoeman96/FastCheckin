defmodule FastCheck.Sales.DeliveryAttempt do
  @moduledoc """
  Durable Sales delivery attempt audit skeleton.

  VS-01D stores delivery history shape only. WhatsApp, email, resend workers,
  and provider integration are deferred.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("sales_delivery_attempts")
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

    read :list_by_order do
      argument :sales_order_id, :integer do
        allow_nil?(false)
      end

      filter(expr(sales_order_id == ^arg(:sales_order_id)))
    end

    read :list_by_ticket_issue do
      argument :ticket_issue_id, :integer do
        allow_nil?(false)
      end

      filter(expr(ticket_issue_id == ^arg(:ticket_issue_id)))
    end

    read :list_by_status do
      argument :status, :string do
        allow_nil?(false)
      end

      filter(expr(status == ^arg(:status)))
    end

    create :create_queued do
      accept([
        :sales_order_id,
        :ticket_issue_id,
        :channel,
        :provider,
        :recipient,
        :template_name,
        :within_whatsapp_window,
        :attempt_number,
        :correlation_id
      ])

      validate(present([:sales_order_id, :channel, :attempt_number]))
      change(set_attribute(:status, "queued"))
    end

    update :mark_sent do
      require_atomic?(false)
      accept([:provider_message_id, :sent_at])
      change(set_attribute(:status, "sent"))
    end

    update :mark_failed do
      require_atomic?(false)
      accept([:provider_error_code, :provider_error_message, :failure_reason])
      change(set_attribute(:status, "failed"))
    end

    update :mark_fallback_required do
      require_atomic?(false)
      accept([:provider_error_code, :provider_error_message, :failure_reason, :fallback_channel])
      change(set_attribute(:status, "fallback_required"))
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

    field_policy [:recipient, :provider_error_message, :failure_reason] do
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

    attribute :channel, :string do
      allow_nil?(false)
    end

    attribute(:provider, :string)
    attribute(:recipient, :string, sensitive?: true)

    attribute :status, :string do
      allow_nil?(false)
    end

    attribute(:template_name, :string)
    attribute(:within_whatsapp_window, :boolean)
    attribute(:provider_message_id, :string)

    attribute :attempt_number, :integer do
      allow_nil?(false)
    end

    attribute(:provider_error_code, :string)
    attribute(:provider_error_message, :string, sensitive?: true)
    attribute(:failure_reason, :string, sensitive?: true)
    attribute(:fallback_channel, :string)
    attribute(:correlation_id, :string)
    attribute(:sent_at, :utc_datetime)
    attribute(:delivered_at, :utc_datetime)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :order, FastCheck.Sales.Order do
      source_attribute(:sales_order_id)
      attribute_type(:integer)
      allow_nil?(false)
    end

    belongs_to :ticket_issue, FastCheck.Sales.TicketIssue do
      source_attribute(:ticket_issue_id)
      attribute_type(:integer)
      allow_nil?(true)
    end
  end
end
