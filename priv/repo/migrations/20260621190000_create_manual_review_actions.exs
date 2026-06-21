defmodule FastCheck.Repo.Migrations.CreateManualReviewActions do
  use Ecto.Migration

  @order_statuses [
    "draft",
    "awaiting_payment",
    "payment_pending",
    "paid_unverified",
    "paid_verified",
    "fulfillment_queued",
    "ticket_issued",
    "partially_issued",
    "manual_review",
    "manual_review_held",
    "issuance_retry_queued",
    "no_fulfillment_closed",
    "cancelled",
    "expired",
    "refunded"
  ]

  @order_statuses_down [
    "draft",
    "awaiting_payment",
    "payment_pending",
    "paid_unverified",
    "paid_verified",
    "fulfillment_queued",
    "ticket_issued",
    "partially_issued",
    "manual_review",
    "cancelled",
    "expired",
    "refunded"
  ]

  @payment_attempt_statuses [
    "initializing",
    "initialized",
    "authorization_url_sent",
    "webhook_received",
    "verification_started",
    "verification_retry_queued",
    "verified_success",
    "verified_amount_mismatch",
    "verified_currency_mismatch",
    "failed",
    "duplicate",
    "manual_review",
    "refunded"
  ]

  @payment_attempt_statuses_down [
    "initializing",
    "initialized",
    "authorization_url_sent",
    "webhook_received",
    "verification_started",
    "verified_success",
    "verified_amount_mismatch",
    "verified_currency_mismatch",
    "failed",
    "duplicate",
    "manual_review",
    "refunded"
  ]

  @subject_types ["order", "payment_attempt", "payment_event", "ticket_issue", "checkout_session"]

  @actions [
    "assign_to_self",
    "unassign",
    "add_note",
    "retry_payment_verification",
    "retry_ticket_issuance",
    "hold_for_investigation",
    "close_no_fulfillment",
    "return_to_fulfillment_queue",
    "return_held_to_manual_review",
    "blocked_return_to_fulfillment_queue"
  ]

  @actor_types ["dashboard_user", "system"]

  def up do
    create table(:sales_manual_review_actions) do
      add(:subject_type, :string, null: false)
      add(:subject_id, :string, null: false)
      add(:sales_order_id, :integer)
      add(:payment_attempt_id, :integer)
      add(:payment_event_id, :integer)
      add(:ticket_issue_id, :integer)
      add(:checkout_session_id, :integer)
      add(:action, :string, null: false)
      add(:reason_code, :string)
      add(:note, :text)
      add(:actor_type, :string, null: false)
      add(:actor_id, :string)
      add(:actor_label, :string)
      add(:previous_status, :string)
      add(:new_status, :string)
      add(:metadata, :map, null: false, default: %{})
      add(:correlation_id, :string)

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create(
      constraint(:sales_manual_review_actions, :sales_manual_review_actions_subject_type_valid,
        check: "subject_type IN (#{quoted_values(@subject_types)})"
      )
    )

    create(
      constraint(:sales_manual_review_actions, :sales_manual_review_actions_action_valid,
        check: "action IN (#{quoted_values(@actions)})"
      )
    )

    create(
      constraint(:sales_manual_review_actions, :sales_manual_review_actions_actor_type_valid,
        check: "actor_type IN (#{quoted_values(@actor_types)})"
      )
    )

    create(
      constraint(:sales_manual_review_actions, :sales_manual_review_actions_reason_code_length,
        check: "reason_code IS NULL OR char_length(reason_code) <= 80"
      )
    )

    create(
      constraint(:sales_manual_review_actions, :sales_manual_review_actions_note_length,
        check: "note IS NULL OR char_length(note) <= 1000"
      )
    )

    create(
      index(:sales_manual_review_actions, [:subject_type, :subject_id, :inserted_at],
        name: :sales_manual_review_actions_subject_idx
      )
    )

    create(
      index(:sales_manual_review_actions, [:sales_order_id, :inserted_at],
        name: :sales_manual_review_actions_order_idx
      )
    )

    create(
      index(:sales_manual_review_actions, [:actor_id, :inserted_at],
        name: :sales_manual_review_actions_actor_idx
      )
    )

    create(
      index(:sales_manual_review_actions, [:action, :inserted_at],
        name: :sales_manual_review_actions_action_idx
      )
    )

    replace_status_constraint(:sales_orders, :sales_orders_status_valid, @order_statuses)

    replace_status_constraint(
      :sales_payment_attempts,
      :sales_payment_attempts_status_valid,
      @payment_attempt_statuses
    )
  end

  def down do
    replace_status_constraint(
      :sales_payment_attempts,
      :sales_payment_attempts_status_valid,
      @payment_attempt_statuses_down
    )

    replace_status_constraint(:sales_orders, :sales_orders_status_valid, @order_statuses_down)

    drop(table(:sales_manual_review_actions))
  end

  defp replace_status_constraint(table, constraint_name, statuses) do
    execute(
      "ALTER TABLE #{table} DROP CONSTRAINT #{constraint_name}",
      "ALTER TABLE #{table} DROP CONSTRAINT #{constraint_name}"
    )

    execute(
      "ALTER TABLE #{table} ADD CONSTRAINT #{constraint_name} CHECK (status IN (#{quoted_values(statuses)}))",
      "ALTER TABLE #{table} DROP CONSTRAINT #{constraint_name}"
    )
  end

  defp quoted_values(values) do
    Enum.map_join(values, ",", &"'#{&1}'")
  end
end
