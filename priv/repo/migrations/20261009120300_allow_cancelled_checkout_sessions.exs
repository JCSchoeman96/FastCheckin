defmodule FastCheck.Repo.Migrations.AllowCancelledCheckoutSessions do
  use Ecto.Migration

  @statuses [
    "created",
    "hold_attached",
    "payment_link_sent",
    "payment_started",
    "paid",
    "expired",
    "released",
    "failed",
    "manual_review",
    "cancelled"
  ]

  @previous_statuses List.delete(@statuses, "cancelled")

  def up do
    drop_status_constraint()
    add_status_constraint(@statuses)
  end

  def down do
    drop_status_constraint()
    add_status_constraint(@previous_statuses)
  end

  defp drop_status_constraint do
    execute(
      "ALTER TABLE sales_checkout_sessions DROP CONSTRAINT sales_checkout_sessions_status_valid"
    )
  end

  defp add_status_constraint(statuses) do
    execute(
      "ALTER TABLE sales_checkout_sessions ADD CONSTRAINT sales_checkout_sessions_status_valid CHECK (status IN (#{quoted_values(statuses)}))"
    )
  end

  defp quoted_values(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
