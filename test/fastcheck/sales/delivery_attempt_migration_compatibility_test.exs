defmodule FastCheck.Sales.DeliveryAttemptMigrationCompatibilityTest do
  use ExUnit.Case, async: true

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260901091000_harden_whatsapp_delivery_attempt_lifecycle.exs",
                    __DIR__
                  )

  test "legacy local-send rows have an explicit provider-acceptance backfill" do
    source = File.read!(@migration_path)

    assert source =~ "SET status = 'provider_accepted'"
    assert source =~ "provider_status = 'accepted'"
    assert source =~ "provider_accepted_at = COALESCE(sent_at, inserted_at)"
    assert source =~ "status = 'sent'"
    assert source =~ "provider_status IS NULL"
    assert source =~ "WHEN 'provider_accepted' THEN 'sent'"
    assert source =~ "WHEN 'read' THEN 'delivered'"
  end

  test "duplicate historical WAMIDs stop the migration before the unique index" do
    source = File.read!(@migration_path)

    assert source =~ "HAVING COUNT(*) > 1"
    assert source =~ "duplicate historical Meta WhatsApp provider message ids"
    assert source =~ "sales_delivery_attempts_meta_wamid_uidx"
  end

  test "the additive migration retains every required lifecycle state" do
    source = File.read!(@migration_path)

    for status <-
          ~w(queued provider_accepted sent delivered read failed fallback_required cancelled manual_review) do
      assert source =~ "\"#{status}\""
    end
  end
end
