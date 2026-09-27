defmodule FastCheck.Repo.Migrations.AllowRetryPaidOrderFulfillmentAction do
  use Ecto.Migration

  @constraint "sales_manual_review_actions_action_valid"

  @previous_actions [
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

  @actions @previous_actions ++ ["retry_paid_order_fulfillment"]

  def up do
    replace_action_constraint(@actions)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM sales_manual_review_actions
        WHERE action = 'retry_paid_order_fulfillment'
      ) THEN
        RAISE EXCEPTION 'Cannot remove retry_paid_order_fulfillment while audit records exist';
      END IF;
    END
    $$;
    """)

    replace_action_constraint(@previous_actions)
  end

  defp replace_action_constraint(actions) do
    quoted_values = Enum.map_join(actions, ",", &"'#{&1}'")

    execute("ALTER TABLE sales_manual_review_actions DROP CONSTRAINT #{@constraint}")

    execute(
      "ALTER TABLE sales_manual_review_actions ADD CONSTRAINT #{@constraint} " <>
        "CHECK (action IN (#{quoted_values}))"
    )
  end
end
