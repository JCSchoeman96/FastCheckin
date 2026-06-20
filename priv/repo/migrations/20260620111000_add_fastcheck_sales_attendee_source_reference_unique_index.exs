defmodule FastCheck.Repo.Migrations.AddFastcheckSalesAttendeeSourceReferenceUniqueIndex do
  use Ecto.Migration

  def change do
    create(
      unique_index(:attendees, [:source, :source_reference],
        name: :attendees_fastcheck_sales_source_reference_uidx,
        where: "source = 'fastcheck_sales' AND source_reference IS NOT NULL"
      )
    )
  end
end
