defmodule FastCheck.Sales.ManualReviewAction do
  @moduledoc """
  Append-only audit record for bounded Sales manual-review operations.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Changeset
  alias FastCheck.Observability.Redactor

  @max_note_length 1000
  @max_reason_length 80

  postgres do
    table("sales_manual_review_actions")
    repo(FastCheck.Repo)
  end

  actions do
    defaults([:read])

    read :list_for_subject do
      argument :subject_type, :string do
        allow_nil?(false)
      end

      argument :subject_id, :string do
        allow_nil?(false)
      end

      filter(expr(subject_type == ^arg(:subject_type) and subject_id == ^arg(:subject_id)))
    end

    create :record_action do
      accept([
        :subject_type,
        :subject_id,
        :sales_order_id,
        :payment_attempt_id,
        :payment_event_id,
        :ticket_issue_id,
        :checkout_session_id,
        :action,
        :reason_code,
        :note,
        :actor_type,
        :actor_id,
        :actor_label,
        :previous_status,
        :new_status,
        :metadata,
        :correlation_id
      ])

      validate(
        present([
          :subject_type,
          :subject_id,
          :action,
          :actor_type
        ])
      )

      validate(&validate_lengths/2)
      change(&sanitize_values/2)
    end
  end

  policies do
    bypass {FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]} do
      authorize_if(always())
    end

    policy action_type(:read) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:admin]})
    end

    policy action(:record_action) do
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:admin]})
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :subject_type, :string do
      allow_nil?(false)
    end

    attribute :subject_id, :string do
      allow_nil?(false)
    end

    attribute(:sales_order_id, :integer)
    attribute(:payment_attempt_id, :integer)
    attribute(:payment_event_id, :integer)
    attribute(:ticket_issue_id, :integer)
    attribute(:checkout_session_id, :integer)

    attribute :action, :string do
      allow_nil?(false)
    end

    attribute(:reason_code, :string)
    attribute(:note, :string)

    attribute :actor_type, :string do
      allow_nil?(false)
    end

    attribute(:actor_id, :string)
    attribute(:actor_label, :string)
    attribute(:previous_status, :string)
    attribute(:new_status, :string)

    attribute :metadata, :map do
      allow_nil?(false)
      default(%{})
    end

    attribute(:correlation_id, :string)

    create_timestamp(:inserted_at)
  end

  defp validate_lengths(changeset, _context) do
    reason = Changeset.get_attribute(changeset, :reason_code)
    note = Changeset.get_attribute(changeset, :note)

    cond do
      is_binary(reason) and String.length(reason) > @max_reason_length ->
        {:error, field: :reason_code, message: "must be at most 80 characters"}

      is_binary(note) and String.length(note) > @max_note_length ->
        {:error, field: :note, message: "must be at most 1000 characters"}

      true ->
        :ok
    end
  end

  defp sanitize_values(changeset, _context) do
    metadata = Changeset.get_attribute(changeset, :metadata) || %{}
    note = Changeset.get_attribute(changeset, :note)

    changeset
    |> Changeset.force_change_attribute(:metadata, Redactor.safe_metadata(metadata))
    |> maybe_sanitize_note(note)
  end

  defp maybe_sanitize_note(changeset, nil), do: changeset

  defp maybe_sanitize_note(changeset, note) when is_binary(note) do
    Changeset.force_change_attribute(changeset, :note, strip_control_characters(note))
  end

  defp strip_control_characters(value) do
    String.replace(value, ~r/[\x00-\x1F\x7F]/u, "")
  end
end
