defmodule FastCheck.Sales.TicketIssue do
  @moduledoc """
  Durable Sales ticket issuance audit skeleton.

  VS-01D stores issuance linkage shape only. Ticket codes, QR/delivery tokens,
  attendee creation, scanner mutation, and delivery workflow are deferred.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("sales_ticket_issues")
    repo(FastCheck.Repo)

    identity_index_names(
      unique_ticket_code: "sales_ticket_issues_ticket_code_uidx",
      unique_line_item_sequence: "sales_ticket_issues_order_line_sequence_uidx",
      unique_attendee_id: "sales_ticket_issues_attendee_id_uidx"
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

    read :list_by_order do
      argument :sales_order_id, :integer do
        allow_nil?(false)
      end

      filter(expr(sales_order_id == ^arg(:sales_order_id)))
    end

    read :list_by_order_line do
      argument :sales_order_line_id, :integer do
        allow_nil?(false)
      end

      filter(expr(sales_order_line_id == ^arg(:sales_order_line_id)))
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :line_item_sequence, :integer do
      allow_nil?(false)
    end

    attribute(:attendee_id, :integer, sensitive?: true)
    attribute(:ticket_code, :string, sensitive?: true)
    attribute(:qr_token_hash, :string, sensitive?: true)
    attribute(:delivery_token_hash, :string, sensitive?: true)
    attribute(:delivery_token_expires_at, :utc_datetime)

    attribute :status, :string do
      allow_nil?(false)
    end

    attribute(:scanner_status, :string)
    attribute(:last_scanner_sync_version, :integer)
    attribute(:issued_at, :utc_datetime)
    attribute(:revoked_at, :utc_datetime)
    attribute(:revocation_reason, :string)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :order, FastCheck.Sales.Order do
      source_attribute(:sales_order_id)
      attribute_type(:integer)
      allow_nil?(false)
    end

    belongs_to :order_line, FastCheck.Sales.OrderLine do
      source_attribute(:sales_order_line_id)
      attribute_type(:integer)
      allow_nil?(false)
    end

    has_many :delivery_attempts, FastCheck.Sales.DeliveryAttempt do
      destination_attribute(:ticket_issue_id)
    end
  end

  identities do
    identity :unique_ticket_code, [:ticket_code] do
      where(expr(not is_nil(ticket_code)))
    end

    identity(:unique_line_item_sequence, [:sales_order_line_id, :line_item_sequence])

    identity :unique_attendee_id, [:attendee_id] do
      where(expr(not is_nil(attendee_id)))
    end
  end
end
