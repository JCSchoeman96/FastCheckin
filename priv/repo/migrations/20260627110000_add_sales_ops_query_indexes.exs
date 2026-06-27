defmodule FastCheck.Repo.Migrations.AddSalesOpsQueryIndexes do
  use Ecto.Migration

  def change do
    create_if_not_exists(
      index(:sales_orders, [:source_channel, :status, :inserted_at],
        name: :sales_orders_source_status_inserted_at_idx
      )
    )

    create_if_not_exists(
      index(:sales_orders, [:status, :inserted_at], name: :sales_orders_status_inserted_at_idx)
    )

    create_if_not_exists(
      index(:sales_payment_attempts, [:status, :inserted_at],
        name: :sales_payment_attempts_status_inserted_at_idx
      )
    )

    create_if_not_exists(
      index(:sales_ticket_issues, [:status, :inserted_at],
        name: :sales_ticket_issues_status_inserted_at_idx
      )
    )

    create_if_not_exists(
      index(:sales_delivery_attempts, [:status, :inserted_at],
        name: :sales_delivery_attempts_status_inserted_at_idx
      )
    )

    create_if_not_exists(
      index(:sales_delivery_attempts, [:ticket_issue_id, :inserted_at],
        name: :sales_delivery_attempts_ticket_issue_inserted_at_idx
      )
    )

    create_if_not_exists(
      index(:sales_delivery_attempts, [:sales_order_id, :inserted_at],
        name: :sales_delivery_attempts_order_inserted_at_idx
      )
    )

    create_if_not_exists(
      index(:sales_conversations, [:state, :needs_human, :last_message_at],
        name: :sales_conversations_state_needs_human_last_message_at_idx
      )
    )
  end
end
