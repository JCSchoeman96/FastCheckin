defmodule FastCheck.Sales.DeliveryAttempt do
  @moduledoc """
  Durable Sales delivery attempt audit skeleton.

  VS-01D stores delivery history shape only. WhatsApp, email, resend workers,
  and provider integration are deferred.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer

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
      allow_nil?(false)
    end
  end
end
