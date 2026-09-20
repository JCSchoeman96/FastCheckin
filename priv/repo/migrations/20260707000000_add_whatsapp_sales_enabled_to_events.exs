defmodule FastCheck.Repo.Migrations.AddWhatsappSalesEnabledToEvents do
  use Ecto.Migration

  @archived_gate_constraint :events_whatsapp_sales_archived_invariant

  def up do
    alter table(:events) do
      add(:whatsapp_sales_enabled, :boolean, null: false, default: false)
    end

    create(
      constraint(:events, @archived_gate_constraint,
        check: "whatsapp_sales_enabled = false OR status <> 'archived'"
      )
    )
  end

  def down do
    drop(constraint(:events, @archived_gate_constraint))

    alter table(:events) do
      remove(:whatsapp_sales_enabled)
    end
  end
end
