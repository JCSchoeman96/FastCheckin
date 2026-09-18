defmodule FastCheck.Sales.DeliveryAttempt do
  @moduledoc """
  Durable provider delivery truth for a Sales delivery attempt.

  Local provider acceptance and later provider delivery evidence are separate
  lifecycle states. Provider callback normalization belongs to WH-H01A.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Changeset

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
        :ticket_resend_challenge_id,
        :channel,
        :provider,
        :recipient,
        :delivery_reason,
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
      validate(&validate_provider_message_id_for_provider_state/2)

      change(fn changeset, _context ->
        transition_provider_status(changeset, "sent", ["provider_accepted"], :sent_at)
      end)

      change(optimistic_lock(:lock_version))
    end

    update :mark_provider_accepted do
      require_atomic?(false)
      accept([:provider_message_id, :provider_accepted_at])
      validate(&validate_usable_provider_message_id/2)

      change(fn changeset, _context ->
        transition_provider_status(
          changeset,
          "accepted",
          ["queued"],
          :provider_accepted_at,
          "provider_accepted"
        )
      end)

      change(optimistic_lock(:lock_version))
    end

    update :mark_delivered do
      require_atomic?(false)
      accept([:provider_message_id, :delivered_at])
      validate(&validate_provider_message_id_for_provider_state/2)

      change(fn changeset, _context ->
        transition_provider_status(
          changeset,
          "delivered",
          ["provider_accepted", "sent"],
          :delivered_at
        )
      end)

      change(optimistic_lock(:lock_version))
    end

    update :mark_read do
      require_atomic?(false)
      accept([:provider_message_id, :read_at])
      validate(&validate_provider_message_id_for_provider_state/2)

      change(fn changeset, _context ->
        transition_provider_status(
          changeset,
          "read",
          ["provider_accepted", "sent", "delivered"],
          :read_at
        )
      end)

      change(optimistic_lock(:lock_version))
    end

    update :mark_failed do
      require_atomic?(false)
      accept([:provider_error_code, :provider_error_message, :failure_reason, :failed_at])

      change(fn changeset, _context ->
        transition_provider_status(
          changeset,
          "failed",
          ["queued", "provider_accepted", "sent"],
          :failed_at
        )
      end)

      change(optimistic_lock(:lock_version))
    end

    update :mark_fallback_required do
      require_atomic?(false)
      accept([:provider_error_code, :provider_error_message, :failure_reason, :fallback_channel])

      change(fn changeset, _context ->
        transition_status(changeset, "fallback_required", ["queued"])
      end)

      change(optimistic_lock(:lock_version))
    end

    update :mark_manual_review do
      require_atomic?(false)
      accept([:provider_error_code, :provider_error_message, :failure_reason, :fallback_channel])

      change(fn changeset, _context ->
        transition_status(
          changeset,
          "manual_review",
          ["queued", "provider_accepted", "sent", "delivered", "failed"]
        )
      end)

      change(optimistic_lock(:lock_version))
    end

    update :mark_cancelled do
      require_atomic?(false)
      accept([:failure_reason])

      change(fn changeset, _context ->
        transition_status(changeset, "cancelled", ["queued", "provider_accepted", "sent"])
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

    attribute(:delivery_reason, :string)
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
    attribute(:provider_accepted_at, :utc_datetime)
    attribute(:provider_status, :string)
    attribute(:provider_status_at, :utc_datetime)
    attribute(:sent_at, :utc_datetime)
    attribute(:delivered_at, :utc_datetime)
    attribute(:read_at, :utc_datetime)
    attribute(:failed_at, :utc_datetime)

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
      allow_nil?(true)
    end

    belongs_to :ticket_resend_challenge, FastCheck.Sales.TicketResendChallenge do
      source_attribute(:ticket_resend_challenge_id)
      attribute_type(:integer)
      allow_nil?(true)
    end
  end

  defp validate_usable_provider_message_id(changeset, _context) do
    if usable_provider_message_id?(Changeset.get_attribute(changeset, :provider_message_id)) do
      :ok
    else
      {:error, field: :provider_message_id, message: "must be present and nonblank"}
    end
  end

  defp validate_provider_message_id_for_provider_state(changeset, _context) do
    if Changeset.get_attribute(changeset, :provider) == "meta" and
         Changeset.get_attribute(changeset, :channel) == "whatsapp" and
         not usable_provider_message_id?(Changeset.get_attribute(changeset, :provider_message_id)) do
      {:error, field: :provider_message_id, message: "must be present and nonblank"}
    else
      :ok
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

  defp transition_provider_status(
         changeset,
         provider_status,
         allowed_from,
         timestamp_field,
         to_status \\ nil
       ) do
    to_status = to_status || provider_status
    from_status = Changeset.get_data(changeset, :status)

    if from_status in allowed_from do
      timestamp =
        Changeset.get_attribute(changeset, timestamp_field) ||
          DateTime.utc_now() |> DateTime.truncate(:second)

      changeset =
        changeset
        |> Changeset.force_change_attribute(:status, to_status)
        |> Changeset.force_change_attribute(timestamp_field, timestamp)
        |> Changeset.force_change_attribute(:provider_status, provider_status)
        |> Changeset.force_change_attribute(:provider_status_at, timestamp)

      if to_status == "provider_accepted" do
        Changeset.force_change_attribute(changeset, :sent_at, nil)
      else
        changeset
      end
    else
      Changeset.add_error(changeset,
        field: :status,
        message: "invalid transition from #{from_status} to #{to_status}"
      )
    end
  end

  defp usable_provider_message_id?(value) when is_binary(value),
    do: String.trim(value) != ""

  defp usable_provider_message_id?(_value), do: false
end
