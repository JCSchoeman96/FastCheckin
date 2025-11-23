defmodule FastCheck.Repo.Migrations.AddMobileAccessSecretToEvents do
  use Ecto.Migration

  def change do
    alter table(:events) do
      add(:mobile_access_secret_encrypted, :string)
    end
  end
end
