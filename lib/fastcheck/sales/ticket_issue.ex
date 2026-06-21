defmodule FastCheck.Sales.TicketIssue do
  @moduledoc """
  Durable Sales ticket issuance audit skeleton.

  VS-01D stores issuance linkage shape only. Ticket codes, QR/delivery tokens,
  attendee creation, scanner mutation, and delivery workflow are deferred.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Changeset
  alias FastCheck.Sales.StateTransitionSupport

  postgres do
    table("sales_ticket_issues")
    repo(FastCheck.Repo)

    identity_index_names(
      unique_ticket_code: "sales_ticket_issues_ticket_code_uidx",
      unique_line_item_sequence: "sales_ticket_issues_order_line_sequence_uidx",
      unique_attendee_id: "sales_ticket_issues_attendee_id_uidx",
      unique_qr_token_hash: "sales_ticket_issues_qr_token_hash_uidx",
      unique_delivery_token_hash: "sales_ticket_issues_delivery_token_hash_uidx"
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

    read :get_by_order_line_sequence do
      get?(true)

      argument :sales_order_line_id, :integer do
        allow_nil?(false)
      end

      argument :line_item_sequence, :integer do
        allow_nil?(false)
      end

      filter(
        expr(
          sales_order_line_id == ^arg(:sales_order_line_id) and
            line_item_sequence == ^arg(:line_item_sequence)
        )
      )
    end

    read :get_by_delivery_token_hash do
      get?(true)

      argument :delivery_token_hash, :string do
        allow_nil?(false)
      end

      filter(expr(delivery_token_hash == ^arg(:delivery_token_hash)))
    end

    create :create_issued_link do
      accept([
        :sales_order_id,
        :sales_order_line_id,
        :line_item_sequence,
        :attendee_id,
        :ticket_code,
        :qr_token_hash,
        :delivery_token_hash,
        :delivery_token_expires_at
      ])

      validate(
        present([
          :sales_order_id,
          :sales_order_line_id,
          :line_item_sequence,
          :attendee_id,
          :ticket_code,
          :qr_token_hash,
          :delivery_token_hash,
          :delivery_token_expires_at
        ])
      )

      change(set_attribute(:status, "issued"))
      change(set_attribute(:scanner_status, "valid"))

      change(fn changeset, _context ->
        Changeset.force_change_attribute(
          changeset,
          :issued_at,
          DateTime.utc_now() |> DateTime.truncate(:second)
        )
      end)

      change(&record_create_issued_link_transition/2)
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

    field_policy [:attendee_id, :ticket_code, :qr_token_hash, :delivery_token_hash] do
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

    identity :unique_qr_token_hash, [:qr_token_hash] do
      where(expr(not is_nil(qr_token_hash)))
    end

    identity :unique_delivery_token_hash, [:delivery_token_hash] do
      where(expr(not is_nil(delivery_token_hash)))
    end
  end

  defp record_create_issued_link_transition(changeset, context) do
    Changeset.after_action(changeset, fn _changeset, record ->
      attrs = %{
        entity_type: "TicketIssue",
        entity_id: Integer.to_string(record.id),
        from_state: nil,
        to_state: "issued",
        reason: "issuer_ticket_issue_linked",
        metadata: %{
          sales_order_id: record.sales_order_id,
          sales_order_line_id: record.sales_order_line_id,
          line_item_sequence: record.line_item_sequence,
          attendee_id: record.attendee_id,
          reason_code: "issuer_ticket_issue_linked"
        },
        correlation_id: transition_correlation_id(context),
        idempotency_key: transition_idempotency_key(context),
        source: "ticket_issue.create_issued_link"
      }

      case StateTransitionSupport.record!(attrs, context) do
        {:ok, _transition} -> {:ok, record}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp transition_correlation_id(context) do
    actor = Map.get(context, :actor, %{})
    Map.get(context, :correlation_id) || Map.get(actor, :correlation_id)
  end

  defp transition_idempotency_key(context) do
    actor = Map.get(context, :actor, %{})
    Map.get(context, :idempotency_key) || Map.get(actor, :idempotency_key)
  end
end
