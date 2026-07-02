defmodule FastCheck.Repo.Migrations.AllowVerifiedResendConversationState do
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
    "collecting_resend_otp",
    "awaiting_verified_resend_delivery"
  ]

  @down_states @up_states -- ["awaiting_verified_resend_delivery"]

  def up do
    replace_state_constraint(@up_states)
  end

  def down do
    execute("""
    UPDATE sales_conversations
    SET state = 'main_menu',
        state_data = state_data
          - 'resend_otp_verified_at'
          - 'resend_otp_verification_status'
          - 'resend_challenge_public_id'
          - 'resend_name'
          - 'resend_email'
          - 'resend_requested_at'
          - 'resend_email_otp_result_status'
          - 'resend_correlation_id',
        updated_at = NOW()
    WHERE state = 'awaiting_verified_resend_delivery'
    """)

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
