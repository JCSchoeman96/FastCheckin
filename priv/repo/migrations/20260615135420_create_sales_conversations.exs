defmodule FastCheck.Repo.Migrations.CreateSalesConversations do
  use Ecto.Migration

  @conversation_states [
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
    "expired"
  ]

  @preferred_languages ["af", "en"]

  def change do
    create table(:sales_conversations) do
      add(:phone_e164, :string, null: false)
      add(:wa_id, :string, null: false)
      add(:session_key, :string)
      add(:rate_limit_key, :string)
      add(:preferred_language, :string, null: false, default: "af")
      add(:locale, :string)
      add(:state, :string, null: false, default: "new")
      add(:state_data, :map, null: false, default: %{})
      add(:last_inbound_message_id, :string)
      add(:last_outbound_message_id, :string)
      add(:last_message_at, :utc_datetime)
      add(:expires_at, :utc_datetime)
      add(:needs_human, :boolean, null: false, default: false)
      add(:handoff_reason, :text)

      timestamps(type: :utc_datetime)
    end

    alter table(:sales_orders) do
      add(:sales_conversation_id, references(:sales_conversations, on_delete: :restrict))
    end

    create(
      constraint(:sales_conversations, :sales_conversations_state_valid,
        check: "state IN (#{quoted_values(@conversation_states)})"
      )
    )

    create(
      constraint(:sales_conversations, :sales_conversations_preferred_language_valid,
        check: "preferred_language IN (#{quoted_values(@preferred_languages)})"
      )
    )

    create(
      constraint(:sales_conversations, :sales_conversations_phone_e164_format,
        check: "phone_e164 ~ '^\\+[1-9][0-9]{7,14}$'"
      )
    )

    create(index(:sales_conversations, [:phone_e164], name: :sales_conversations_phone_e164_idx))
    create(index(:sales_conversations, [:wa_id], name: :sales_conversations_wa_id_idx))

    create(
      index(:sales_conversations, [:session_key], name: :sales_conversations_session_key_idx)
    )

    create(
      index(:sales_conversations, [:needs_human, :last_message_at],
        name: :sales_conversations_needs_human_last_message_at_idx
      )
    )

    create(
      index(:sales_conversations, [:state, :expires_at],
        name: :sales_conversations_state_expires_at_idx
      )
    )

    create(
      index(:sales_conversations, [:last_message_at],
        name: :sales_conversations_last_message_at_idx
      )
    )

    create(
      index(:sales_orders, [:sales_conversation_id],
        name: :sales_orders_sales_conversation_id_idx
      )
    )
  end

  defp quoted_values(values) do
    Enum.map_join(values, ",", &"'#{&1}'")
  end
end
