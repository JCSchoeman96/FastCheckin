defmodule FastCheck.Repo.Migrations.AddWhatsappSalesHardeningFields do
  use Ecto.Migration

  def change do
    alter table(:events) do
      add(:whatsapp_sales_enabled, :boolean, null: false, default: false)
    end
  end
end
