defmodule FastCheck.Repo.Migrations.AddDispatchingDeliveryAttemptStatus do
  use Ecto.Migration

  @statuses_with_dispatching [
    "queued",
    "dispatching",
    "provider_accepted",
    "sent",
    "delivered",
    "read",
    "failed",
    "fallback_required",
    "cancelled",
    "manual_review"
  ]

  @previous_statuses [
    "queued",
    "provider_accepted",
    "sent",
    "delivered",
    "read",
    "failed",
    "fallback_required",
    "cancelled",
    "manual_review"
  ]

  def up do
    drop(constraint(:sales_delivery_attempts, :sales_delivery_attempts_status_valid))

    alter table(:sales_delivery_attempts) do
      modify(:status, :string, null: false)
    end

    create(
      constraint(:sales_delivery_attempts, :sales_delivery_attempts_status_valid,
        check: "status IN (#{Enum.map_join(@statuses_with_dispatching, ", ", &"'#{&1}'")})"
      )
    )
  end

  def down do
    execute("""
    UPDATE sales_delivery_attempts
    SET status = 'manual_review',
        failure_reason = 'unresolved_dispatching_rollback',
        fallback_channel = 'manual_review'
    WHERE status = 'dispatching'
    """)

    drop(constraint(:sales_delivery_attempts, :sales_delivery_attempts_status_valid))

    create(
      constraint(:sales_delivery_attempts, :sales_delivery_attempts_status_valid,
        check: "status IN (#{Enum.map_join(@previous_statuses, ", ", &"'#{&1}'")})"
      )
    )
  end
end
