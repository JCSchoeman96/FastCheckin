defmodule FastCheck.Repo.Migrations.AddInternalPilotSourceChannel do
  use Ecto.Migration

  @source_channels ["web", "whatsapp", "admin", "system", "test", "internal_pilot"]

  def up do
    drop(constraint(:sales_orders, "sales_orders_source_channel_valid"))

    create(
      constraint(:sales_orders, :sales_orders_source_channel_valid,
        check: "source_channel IN (#{quoted_values(@source_channels)})"
      )
    )
  end

  def down do
    drop(constraint(:sales_orders, "sales_orders_source_channel_valid"))

    create(
      constraint(:sales_orders, :sales_orders_source_channel_valid,
        check: "source_channel IN ('web', 'whatsapp', 'admin', 'system', 'test')"
      )
    )
  end

  defp quoted_values(values) do
    values
    |> Enum.map(&"'#{&1}'")
    |> Enum.join(", ")
  end
end
