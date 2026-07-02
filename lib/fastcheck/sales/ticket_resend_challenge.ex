defmodule FastCheck.Sales.TicketResendChallenge do
  @moduledoc """
  Durable system-owned ticket resend OTP challenge.

  This resource stores hashed request and OTP material only. It does not deliver
  tickets, rotate delivery tokens, enqueue jobs, or send email/WhatsApp messages.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Changeset
  alias FastCheck.Observability.Redactor

  postgres do
    table("sales_ticket_resend_challenges")
    repo(FastCheck.Repo)

    identity_index_names(unique_public_id: "sales_ticket_resend_challenges_public_id_uidx")
  end

  actions do
    defaults([:read])

    read :get_by_public_id do
      get?(true)

      argument :public_id, :string do
        allow_nil?(false)
      end

      filter(expr(public_id == ^arg(:public_id)))
    end

    create :create_pending do
      accept([
        :public_id,
        :sales_order_id,
        :ticket_issue_id,
        :conversation_id,
        :request_email_hash,
        :request_name_hash,
        :source_hash,
        :candidate_hash,
        :otp_hash,
        :expires_at,
        :metadata
      ])

      validate(present([:public_id, :request_email_hash, :expires_at]))
      change(set_attribute(:status, "pending"))
      change(set_attribute(:failed_attempt_count, 0))
      change(&sanitize_metadata/2)
    end

    update :mark_verified do
      require_atomic?(false)
      accept([:verified_at])

      change(fn changeset, _context ->
        guard_transition(changeset, "verified",
          allowed_from: ["pending"],
          require_available?: true
        )
      end)
    end

    update :mark_consumed do
      require_atomic?(false)
      accept([:consumed_at])

      change(fn changeset, _context ->
        guard_transition(changeset, "consumed", allowed_from: ["verified"])
      end)
    end

    update :mark_expired do
      require_atomic?(false)
      accept([])

      change(fn changeset, _context ->
        guard_transition(changeset, "expired", allowed_from: ["pending", "verified"])
      end)
    end

    update :mark_blocked do
      require_atomic?(false)
      accept([:failure_reason, :locked_until])

      change(fn changeset, _context ->
        guard_transition(changeset, "blocked", allowed_from: ["pending"])
      end)
    end

    update :mark_manual_review do
      require_atomic?(false)
      accept([:failure_reason])

      change(fn changeset, _context ->
        guard_transition(changeset, "manual_review", allowed_from: ["pending"])
      end)
    end

    update :increment_failed_attempt do
      require_atomic?(false)
      accept([:failed_attempt_count, :locked_until, :failure_reason])

      change(fn changeset, _context ->
        if Changeset.get_data(changeset, :status) == "pending" do
          changeset
        else
          Changeset.add_error(changeset,
            field: :status,
            message: "invalid lifecycle transition"
          )
        end
      end)
    end
  end

  policies do
    bypass {FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]} do
      authorize_if(always())
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

    attribute :public_id, :string do
      allow_nil?(false)
    end

    attribute(:sales_order_id, :integer)
    attribute(:ticket_issue_id, :integer)
    attribute(:conversation_id, :integer)

    attribute :request_email_hash, :string do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute(:request_name_hash, :string, sensitive?: true)
    attribute(:source_hash, :string, sensitive?: true)
    attribute(:candidate_hash, :string, sensitive?: true)
    attribute(:otp_hash, :string, sensitive?: true)

    attribute :status, :string do
      allow_nil?(false)
    end

    attribute(:failure_reason, :string, sensitive?: true)

    attribute :failed_attempt_count, :integer do
      allow_nil?(false)
      default(0)
    end

    attribute :expires_at, :utc_datetime do
      allow_nil?(false)
    end

    attribute(:verified_at, :utc_datetime)
    attribute(:consumed_at, :utc_datetime)
    attribute(:locked_until, :utc_datetime)

    attribute :metadata, :map do
      allow_nil?(false)
      default(%{})
      sensitive?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :order, FastCheck.Sales.Order do
      source_attribute(:sales_order_id)
      attribute_type(:integer)
      allow_nil?(true)
    end

    belongs_to :ticket_issue, FastCheck.Sales.TicketIssue do
      source_attribute(:ticket_issue_id)
      attribute_type(:integer)
      allow_nil?(true)
    end

    belongs_to :conversation, FastCheck.Sales.Conversation do
      source_attribute(:conversation_id)
      attribute_type(:integer)
      allow_nil?(true)
    end
  end

  identities do
    identity(:unique_public_id, [:public_id])
  end

  defp sanitize_metadata(changeset, _context) do
    metadata = Changeset.get_attribute(changeset, :metadata) || %{}
    Changeset.force_change_attribute(changeset, :metadata, Redactor.safe_metadata(metadata))
  end

  defp guard_transition(changeset, to_status, opts) do
    from_status = Changeset.get_data(changeset, :status)
    allowed_from = Keyword.fetch!(opts, :allowed_from)

    cond do
      from_status not in allowed_from ->
        Changeset.add_error(changeset,
          field: :status,
          message: "invalid lifecycle transition"
        )

      Keyword.get(opts, :require_available?, false) and not available_for_verification?(changeset) ->
        Changeset.add_error(changeset,
          field: :status,
          message: "challenge is not available for verification"
        )

      true ->
        Changeset.force_change_attribute(changeset, :status, to_status)
    end
  end

  defp available_for_verification?(changeset) do
    now = DateTime.utc_now()
    expires_at = Changeset.get_data(changeset, :expires_at)
    locked_until = Changeset.get_data(changeset, :locked_until)

    DateTime.compare(expires_at, now) == :gt and
      (is_nil(locked_until) or DateTime.compare(locked_until, now) != :gt)
  end
end

defimpl Inspect, for: FastCheck.Sales.TicketResendChallenge do
  import Inspect.Algebra

  def inspect(challenge, opts) do
    safe = %{
      public_id: challenge.public_id,
      status: challenge.status,
      failed_attempt_count: challenge.failed_attempt_count,
      expires_at: challenge.expires_at,
      verified?: not is_nil(challenge.verified_at),
      consumed?: not is_nil(challenge.consumed_at),
      locked?: not is_nil(challenge.locked_until)
    }

    concat(["#FastCheck.Sales.TicketResendChallenge<", to_doc(safe, opts), ">"])
  end
end
