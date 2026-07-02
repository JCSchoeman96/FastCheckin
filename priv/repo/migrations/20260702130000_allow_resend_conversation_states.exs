defmodule FastCheck.Repo.Migrations.AllowResendConversationStates do
  use Ecto.Migration

  @constraint "sales_conversations_state_valid"

  @up_states [
    "new",
    "selecting_language",
    "main_menu",
    "selecting_event",
    "selecting_ticket_type",
    "collecting_quantity",
    "collecting_buyer_name",
    "collecting_email",
    "confirming_order",
    "awaiting_payment",
    "payment_pending",
    "payment_received",
    "ticket_issued",
    "completed",
    "manual_review",
    "cancelled",
    "expired",
    "collecting_resend_name",
    "collecting_resend_email",
    "collecting_resend_otp"
  ]

  @down_states @up_states --
                 [
                   "collecting_resend_name",
                   "collecting_resend_email",
                   "collecting_resend_otp"
                 ]

  def up do
    replace_state_constraint(@up_states)
  end

  def down do
    replace_state_constraint(@down_states)
  end

  defp replace_state_constraint(states) do
    execute("ALTER TABLE sales_conversations DROP CONSTRAINT #{@constraint}")

    execute("""
    ALTER TABLE sales_conversations
    ADD CONSTRAINT #{@constraint}
    CHECK (state IN (#{quoted_values(states)}))
    """)
  end

  defp quoted_values(values) do
    values
    |> Enum.map(&"'#{&1}'")
    |> Enum.join(",")
  end
end
