defmodule FastCheck.Sales.H13aLockTimeoutMigrationTest do
  use ExUnit.Case, async: true

  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)

  @phase1 Path.join(
            @migrations_path,
            "20260922150000_wh_h13a_align_sales_event_id_types.exs"
          )
  @phase2 Path.join(
            @migrations_path,
            "20260922150100_wh_h13a_add_sales_event_fkeys_not_valid.exs"
          )
  @phase3 Path.join(
            @migrations_path,
            "20260922150200_wh_h13a_validate_sales_event_fkeys.exs"
          )

  test "H13A DDL phases use a transaction-local five-second lock timeout" do
    phase1 = File.read!(@phase1)
    phase2 = File.read!(@phase2)
    phase3 = File.read!(@phase3)

    assert phase1 =~
             ~r/def up do\s+repo\(\)\.query!\("SET LOCAL lock_timeout = '5s'"\)\s+assert_no_orphan_sales_event_ids!\(\)/

    assert phase1 =~
             ~r/def down do\s+repo\(\)\.query!\("SET LOCAL lock_timeout = '5s'"\)\s+assert_sales_event_ids_fit_integer!\(\)/

    assert phase2 =~
             ~r/def up do\s+repo\(\)\.query!\("SET LOCAL lock_timeout = '5s'"\)\s+execute\("""/

    assert phase2 =~
             ~r/def down do\s+repo\(\)\.query!\("SET LOCAL lock_timeout = '5s'"\)\s+execute\("ALTER TABLE sales_orders DROP CONSTRAINT/

    assert phase3 =~
             ~r/def up do\s+repo\(\)\.query!\("SET LOCAL lock_timeout = '5s'"\)\s+execute\("ALTER TABLE sales_orders VALIDATE CONSTRAINT/

    assert phase3 =~ ~r/def down do\s+:ok\s+end/
  end
end
