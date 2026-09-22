defmodule FastCheck.Repo.Migrations.AddWhatsappMaxTicketsPerOrderToEvents do
  use Ecto.Migration

  @positive_constraint :events_whatsapp_max_tickets_per_order_positive

  def up do
    alter table(:events) do
      add(:whatsapp_max_tickets_per_order, :integer, null: false, default: 9)
    end

    create(constraint(:events, @positive_constraint, check: "whatsapp_max_tickets_per_order > 0"))
  end

  def down do
    drop(constraint(:events, @positive_constraint))

    alter table(:events) do
      remove(:whatsapp_max_tickets_per_order)
    end
  end
end
