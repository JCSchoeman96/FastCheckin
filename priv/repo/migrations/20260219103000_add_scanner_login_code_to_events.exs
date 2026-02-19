defmodule FastCheck.Repo.Migrations.AddScannerLoginCodeToEvents do
  use Ecto.Migration

  @scanner_code_constraint "events_scanner_login_code_format"
  @scanner_code_index :idx_events_scanner_login_code
  @scanner_code_length 6
  @scanner_code_space 1_073_741_824
  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  def up do
    alter table(:events) do
      add(:scanner_login_code, :string, size: @scanner_code_length)
    end

    flush()
    backfill_existing_events()

    execute("""
    ALTER TABLE events
    ALTER COLUMN scanner_login_code SET NOT NULL
    """)

    create(unique_index(:events, [:scanner_login_code], name: @scanner_code_index))

    create(
      constraint(:events, @scanner_code_constraint,
        check: "scanner_login_code ~ '^[0-9A-HJKMNP-TV-Z]{6}$'"
      )
    )
  end

  def down do
    drop_if_exists(constraint(:events, @scanner_code_constraint))
    drop_if_exists(index(:events, [:scanner_login_code], name: @scanner_code_index))

    alter table(:events) do
      remove(:scanner_login_code)
    end
  end

  defp backfill_existing_events do
    rows =
      repo().query!("SELECT id FROM events WHERE scanner_login_code IS NULL ORDER BY id").rows

    Enum.each(rows, fn [id] ->
      code = encode_scanner_code(id)
      repo().query!("UPDATE events SET scanner_login_code = $1 WHERE id = $2", [code, id])
    end)
  end

  defp encode_scanner_code(id) when is_integer(id) and id >= 0 and id < @scanner_code_space do
    id
    |> do_encode_scanner_code([])
    |> IO.iodata_to_binary()
    |> String.pad_leading(@scanner_code_length, "0")
  end

  defp encode_scanner_code(id) do
    raise "Unable to encode event id #{inspect(id)} as #{@scanner_code_length}-char scanner code"
  end

  defp do_encode_scanner_code(value, acc) when value < 32 do
    [<<Enum.at(@alphabet, value)>> | acc]
  end

  defp do_encode_scanner_code(value, acc) do
    remainder = rem(value, 32)
    quotient = div(value, 32)

    do_encode_scanner_code(quotient, [<<Enum.at(@alphabet, remainder)>> | acc])
  end
end
