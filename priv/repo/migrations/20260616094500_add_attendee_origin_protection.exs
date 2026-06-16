defmodule FastCheck.Repo.Migrations.AddAttendeeOriginProtection do
  use Ecto.Migration

  def change do
    alter table(:attendees) do
      add(:source, :string, null: false, default: "tickera")
      add(:source_reference, :string)
      add(:sales_order_id, :integer)
      add(:sales_ticket_issue_id, :integer)
      add(:revoked_at, :utc_datetime)
      add(:revocation_reason, :text)
    end

    create(
      constraint(:attendees, :attendees_source_valid,
        check: "source IN ('tickera', 'fastcheck_sales', 'manual', 'import', 'test')"
      )
    )

    create(index(:attendees, [:source], name: :attendees_source_idx))

    create(
      index(:attendees, [:source, :source_reference],
        name: :attendees_source_source_reference_idx
      )
    )

    create(
      index(:attendees, [:sales_order_id],
        where: "sales_order_id IS NOT NULL",
        name: :attendees_sales_order_id_idx
      )
    )

    create(
      unique_index(:attendees, [:sales_ticket_issue_id],
        where: "sales_ticket_issue_id IS NOT NULL",
        name: :attendees_sales_ticket_issue_id_uidx
      )
    )

    create(index(:attendees, [:event_id, :source], name: :attendees_event_id_source_idx))
  end
end
