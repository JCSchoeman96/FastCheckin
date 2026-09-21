defmodule FastCheck.Repo.Migrations.AddRegularPriceToSalesTicketOffers do
  use Ecto.Migration

  @pricing_constraint :sales_ticket_offers_regular_price_invariant

  def up do
    alter table(:sales_ticket_offers) do
      add(:regular_price_cents, :integer, null: true)
    end

    create(
      constraint(:sales_ticket_offers, @pricing_constraint,
        check: "regular_price_cents IS NULL OR regular_price_cents >= price_cents"
      )
    )
  end

  def down do
    drop(constraint(:sales_ticket_offers, @pricing_constraint))

    alter table(:sales_ticket_offers) do
      remove(:regular_price_cents)
    end
  end
end
