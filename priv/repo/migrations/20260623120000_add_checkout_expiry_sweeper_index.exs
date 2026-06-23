defmodule FastCheck.Repo.Migrations.AddCheckoutExpirySweeperIndex do
  use Ecto.Migration

  def up do
    create(
      index(
        :sales_checkout_sessions,
        [:expires_at, :id],
        name: :sales_checkout_sessions_expiry_sweep_idx,
        where:
          "status IN ('hold_attached', 'payment_link_sent', 'payment_started') AND expired_at IS NULL"
      )
    )
  end

  def down do
    drop(index(:sales_checkout_sessions, [], name: :sales_checkout_sessions_expiry_sweep_idx))
  end
end
