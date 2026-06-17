defmodule FastCheck.Repo.Migrations.AddPaymentAttemptInitializingAndActiveIdempotency do
  use Ecto.Migration

  @payment_attempt_statuses [
    "initializing",
    "initialized",
    "authorization_url_sent",
    "webhook_received",
    "verification_started",
    "verified_success",
    "verified_amount_mismatch",
    "verified_currency_mismatch",
    "failed",
    "duplicate",
    "manual_review",
    "refunded"
  ]

  def up do
    drop(constraint(:sales_payment_attempts, :sales_payment_attempts_status_valid))

    create(
      constraint(:sales_payment_attempts, :sales_payment_attempts_status_valid,
        check: "status IN (#{quoted_values(@payment_attempt_statuses)})"
      )
    )

    create(
      unique_index(:sales_payment_attempts, [:idempotency_key],
        name: :sales_payment_attempts_idempotency_key_active_uidx,
        where: "idempotency_key IS NOT NULL AND status IN ('initializing', 'initialized')"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:sales_payment_attempts, [:idempotency_key],
        name: :sales_payment_attempts_idempotency_key_active_uidx
      )
    )

    drop(constraint(:sales_payment_attempts, :sales_payment_attempts_status_valid))

    old_statuses =
      @payment_attempt_statuses
      |> Enum.reject(&(&1 == "initializing"))

    create(
      constraint(:sales_payment_attempts, :sales_payment_attempts_status_valid,
        check: "status IN (#{quoted_values(old_statuses)})"
      )
    )
  end

  defp quoted_values(values) do
    values
    |> Enum.map(&"'#{&1}'")
    |> Enum.join(", ")
  end
end
