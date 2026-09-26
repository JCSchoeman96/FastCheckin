defmodule FastCheck.Sales.H13aDownIntegerRangeGuardTest do
  @moduledoc """
  Behavioral regression for WH-H13A phase-1 down migration int32 range guard.

  Exercises `assert_sales_event_ids_fit_integer!/0` via the migration's `down/0`
  without recording a schema rollback in `schema_migrations`.
  """
  use FastCheck.DataCase, async: false

  alias FastCheck.Fixtures
  alias FastCheck.Repo

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260922150000_wh_h13a_align_sales_event_id_types.exs",
                    __DIR__
                  )
  @migration_version 20_260_922_150_000
  @int32_min -2_147_483_648
  @int32_max 2_147_483_647

  setup_all do
    Code.compile_file(@migration_path)
    :ok
  end

  describe "H13A phase-1 down migration int32 range guard" do
    test "accepts event_id at int32 upper bound #{@int32_max}" do
      assert {:error, :cleanup} =
               Repo.transaction(fn ->
                 event_id = @int32_max
                 insert_event_with_id!(event_id)
                 insert_sales_order!(event_id)
                 run_phase1_down()
                 Repo.rollback(:cleanup)
               end)

      assert_sales_orders_event_id_still_bigint()
    end

    test "accepts event_id at int32 lower bound #{@int32_min}" do
      assert {:error, :cleanup} =
               Repo.transaction(fn ->
                 event_id = @int32_min
                 insert_event_with_id!(event_id)
                 insert_sales_order!(event_id)
                 run_phase1_down()
                 Repo.rollback(:cleanup)
               end)

      assert_sales_orders_event_id_still_bigint()
    end

    test "rejects event_id above int32 max before casting to integer" do
      event_id = @int32_max + 1
      insert_event_with_id!(event_id)
      insert_sales_order!(event_id)

      assert_raise RuntimeError,
                   ~r/WH-H13A down blocked: sales event_id outside integer range/,
                   fn ->
                     run_phase1_down()
                   end

      assert_sales_orders_event_id_still_bigint()
      cleanup_sales_row!(event_id)
      cleanup_event!(event_id)
    end

    test "rejects event_id below int32 min before casting to integer" do
      event_id = @int32_min - 1
      insert_event_with_id!(event_id)
      insert_sales_order!(event_id)

      assert_raise RuntimeError,
                   ~r/WH-H13A down blocked: sales event_id outside integer range/,
                   fn ->
                     run_phase1_down()
                   end

      assert_sales_orders_event_id_still_bigint()
      cleanup_sales_row!(event_id)
      cleanup_event!(event_id)
    end
  end

  defp run_phase1_down do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @migration_version,
      FastCheck.Repo.Migrations.WhH13aAlignSalesEventIdTypes,
      :forward,
      :down,
      :down,
      log: false
    )
  end

  defp insert_event_with_id!(event_id) do
    Repo.query!(
      """
      INSERT INTO events
        (id, name, site_url, tickera_site_url, tickera_api_key_encrypted,
         tickera_api_key_last4, mobile_access_secret_encrypted, scanner_login_code,
         status, inserted_at, updated_at)
      VALUES
        ($1, $2, 'https://example.test', 'https://example.test',
         'encrypted-api-key', 'ikey', 'encrypted-mobile-secret', $3, 'active',
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [event_id, "H13A int32 guard #{event_id}", Fixtures.unique_scanner_login_code()]
    )
  end

  defp insert_sales_order!(event_id) do
    Repo.query!(
      """
      INSERT INTO sales_orders
        (public_reference, event_id, source_channel, status, total_amount_cents, currency,
         idempotency_key, inserted_at, updated_at)
      VALUES
        ($1, $2, 'test', 'draft', 100, 'ZAR', $3,
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [
        "h13a-range-#{System.unique_integer([:positive])}",
        event_id,
        "h13a-idem-#{System.unique_integer([:positive])}"
      ]
    )
  end

  defp cleanup_sales_row!(event_id) do
    Repo.query!("DELETE FROM sales_orders WHERE event_id = $1", [event_id])
  end

  defp cleanup_event!(event_id) do
    Repo.query!("DELETE FROM events WHERE id = $1", [event_id])
  end

  defp assert_sales_orders_event_id_still_bigint do
    assert [["bigint"]] =
             Repo.query!("""
             SELECT data_type
             FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'sales_orders'
               AND column_name = 'event_id'
             """).rows
  end
end
