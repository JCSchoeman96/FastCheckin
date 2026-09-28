defmodule FastCheck.Sales.TicketDeliveryIntent do
  @moduledoc """
  Durable identity for one customer request to deliver a ticket.

  A logical intent can own several `FastCheck.Sales.DeliveryAttempt` rows when
  a safe local transport failure requires another attempt.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Changeset

  postgres do
    table("sales_ticket_delivery_intents")
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

    read :get_initial_for_ticket_issue do
      get?(true)

      argument :ticket_issue_id, :integer do
        allow_nil?(false)
      end

      filter(
        expr(
          ticket_issue_id == ^arg(:ticket_issue_id) and
            purpose == "initial_ticket_delivery"
        )
      )
    end

    read :get_for_resend_challenge do
      get?(true)

      argument :ticket_resend_challenge_id, :integer do
        allow_nil?(false)
      end

      filter(expr(ticket_resend_challenge_id == ^arg(:ticket_resend_challenge_id)))
    end

    create :create_queued do
      accept([
        :sales_order_id,
        :ticket_issue_id,
        :conversation_id,
        :ticket_resend_challenge_id,
        :purpose
      ])

      validate(present([:sales_order_id, :ticket_issue_id, :conversation_id, :purpose]))

      validate(&validate_purpose/2)
      change(set_attribute(:status, "queued"))
    end

    update :mark_provider_accepted do
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        transition_status(changeset, "provider_accepted", ["queued", "manual_review"])
      end)

      change(optimistic_lock(:lock_version))
    end

    update :mark_fallback_required do
      require_atomic?(false)
      accept([:failure_reason])

      change(fn changeset, _context ->
        transition_status(changeset, "fallback_required", ["queued"])
      end)

      change(optimistic_lock(:lock_version))
    end

    update :mark_manual_review do
      require_atomic?(false)
      accept([:failure_reason])

      change(fn changeset, _context ->
        transition_status(changeset, "manual_review", ["queued"])
      end)

      change(optimistic_lock(:lock_version))
    end

    update :mark_cancelled do
      require_atomic?(false)
      accept([:failure_reason])

      change(fn changeset, _context ->
        transition_status(changeset, "cancelled", ["queued"])
      end)

      change(optimistic_lock(:lock_version))
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

    attribute :purpose, :string do
      allow_nil?(false)
    end

    attribute :status, :string do
      allow_nil?(false)
    end

    attribute(:failure_reason, :string)

    attribute :lock_version, :integer do
      allow_nil?(false)
      default(1)
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

    belongs_to :ticket_issue, FastCheck.Sales.TicketIssue do
      source_attribute(:ticket_issue_id)
      attribute_type(:integer)
      allow_nil?(false)
    end

    belongs_to :conversation, FastCheck.Sales.Conversation do
      source_attribute(:conversation_id)
      attribute_type(:integer)
      allow_nil?(false)
    end

    belongs_to :ticket_resend_challenge, FastCheck.Sales.TicketResendChallenge do
      source_attribute(:ticket_resend_challenge_id)
      attribute_type(:integer)
      allow_nil?(true)
    end

    has_many :delivery_attempts, FastCheck.Sales.DeliveryAttempt do
      destination_attribute(:ticket_delivery_intent_id)
    end
  end

  defp validate_purpose(changeset, _context) do
    purpose = Changeset.get_attribute(changeset, :purpose)
    challenge_id = Changeset.get_attribute(changeset, :ticket_resend_challenge_id)

    case {purpose, challenge_id} do
      {"initial_ticket_delivery", nil} -> :ok
      {"verified_ticket_resend", id} when is_integer(id) and id > 0 -> :ok
      _ -> {:error, field: :purpose, message: "does not match resend challenge"}
    end
  end

  defp transition_status(changeset, to_status, allowed_from) do
    from_status = Changeset.get_data(changeset, :status)

    if from_status in allowed_from do
      Changeset.force_change_attribute(changeset, :status, to_status)
    else
      Changeset.add_error(changeset,
        field: :status,
        message: "invalid transition from #{from_status} to #{to_status}"
      )
    end
  end
end
