defmodule FastCheck.Repo.Migrations.AllowNullableSalesTicketOfferWindows do
  use Ecto.Migration

  @sales_channels ["whatsapp", "admin", "web", "all", "internal"]

  def change do
    alter table(:sales_ticket_offers) do
      modify(:starts_at, :utc_datetime, null: true)
      modify(:ends_at, :utc_datetime, null: true)
    end

    create(
      constraint(:sales_ticket_offers, :sales_ticket_offers_sales_channel_valid,
        check: "sales_channel IN (#{quoted_values(@sales_channels)})"
      )
    )

    create(
      constraint(:sales_ticket_offers, :sales_ticket_offers_window_valid,
        check: "starts_at IS NULL OR ends_at IS NULL OR ends_at > starts_at"
      )
    )

    create(
      constraint(:sales_ticket_offers, :sales_ticket_offers_max_per_order_within_configured,
        check:
          "(configured_quantity_available = 0 AND max_per_order >= 1) OR " <>
            "(configured_quantity_available > 0 AND max_per_order <= configured_quantity_available)"
      )
    )
  end

  defp quoted_values(values) do
    Enum.map_join(values, ",", &"'#{&1}'")
  end
end
