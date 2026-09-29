defmodule FastCheck.Repo.Migrations.CreateSalesRefunds do
  use Ecto.Migration

  @refund_statuses [
    "evidence_recorded",
    "revocation_complete",
    "inventory_pending",
    "revocation_manual_review",
    "inventory_manual_review",
    "completed"
  ]

  @inventory_resolution_statuses ["released_unconsumed", "retained_consumed"]

  def up do
    create table(:sales_refunds) do
      add(:sales_order_id, references(:sales_orders, on_delete: :restrict), null: false)

      add(
        :payment_attempt_id,
        references(:sales_payment_attempts, on_delete: :restrict),
        null: false
      )

      add(:provider, :string, null: false)
      add(:provider_status, :string, null: false)
      add(:provider_refund_reference, :string, null: false)
      add(:provider_refunded_at, :utc_datetime, null: false)
      add(:amount_cents, :bigint, null: false)
      add(:currency, :string, null: false)
      add(:status, :string, null: false, default: "evidence_recorded")
      add(:lock_version, :integer, null: false, default: 1)
      add(:inventory_resolution_status, :string)
      add(:recorded_by, :string, null: false)
      add(:reason, :text, null: false)
      add(:revocation_completed_at, :utc_datetime)
      add(:completed_at, :utc_datetime)
      add(:manual_review_reason, :string)

      timestamps(type: :utc_datetime, null: false)
    end

    create(
      constraint(:sales_refunds, :sales_refunds_provider_valid,
        check: "provider = 'paystack' AND provider_status = 'processed'"
      )
    )

    create(
      constraint(:sales_refunds, :sales_refunds_reference_nonblank,
        check: "length(btrim(provider_refund_reference)) > 0"
      )
    )

    create(constraint(:sales_refunds, :sales_refunds_amount_positive, check: "amount_cents > 0"))

    create(
      constraint(:sales_refunds, :sales_refunds_reason_nonblank,
        check: "length(btrim(reason)) > 0"
      )
    )

    create(
      constraint(:sales_refunds, :sales_refunds_recorded_by_nonblank,
        check: "length(btrim(recorded_by)) > 0"
      )
    )

    create(
      constraint(:sales_refunds, :sales_refunds_status_valid,
        check: "status IN (#{quoted_values(@refund_statuses)})"
      )
    )

    create(
      constraint(:sales_refunds, :sales_refunds_inventory_resolution_valid,
        check:
          "inventory_resolution_status IS NULL OR " <>
            "inventory_resolution_status IN (#{quoted_values(@inventory_resolution_statuses)})"
      )
    )

    create(
      constraint(:sales_refunds, :sales_refunds_completed_resolution_valid,
        check:
          "(status = 'completed' AND inventory_resolution_status IS NOT NULL AND completed_at IS NOT NULL) OR " <>
            "(status <> 'completed' AND inventory_resolution_status IS NULL AND completed_at IS NULL)"
      )
    )

    create(unique_index(:sales_refunds, [:sales_order_id], name: :sales_refunds_order_uidx))

    create(
      unique_index(:sales_refunds, [:payment_attempt_id],
        name: :sales_refunds_payment_attempt_uidx
      )
    )

    create(
      unique_index(:sales_refunds, [:provider_refund_reference],
        name: :sales_refunds_provider_reference_uidx
      )
    )

    create(index(:sales_refunds, [:status, :sales_order_id]))
  end

  def down do
    drop(table(:sales_refunds))
  end

  defp quoted_values(values) do
    values
    |> Enum.map(&"'#{&1}'")
    |> Enum.join(", ")
  end
end
