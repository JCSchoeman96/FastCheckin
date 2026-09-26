defmodule FastCheck.Repo.Migrations.AddAdmissionModeToEvents do
  use Ecto.Migration

  def change do
    alter table(:events) do
      add(:admission_mode, :string, null: false, default: "session")
    end

    create(
      constraint(:events, :events_admission_mode_valid,
        check: "admission_mode IN ('session', 'turnstile')"
      )
    )
  end
end
