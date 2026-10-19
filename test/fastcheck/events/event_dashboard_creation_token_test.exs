defmodule FastCheck.Events.EventDashboardCreationTokenTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Events.Event

  test "dashboard creation token column is nullable uuid with no default" do
    assert [["uuid", "YES", nil]] =
             Repo.query!("""
             SELECT data_type, is_nullable, column_default
             FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'events'
               AND column_name = 'dashboard_creation_token'
             """).rows
  end

  test "multiple Events without a dashboard creation token coexist" do
    first = create_event()
    second = create_event()

    assert [[nil], [nil]] =
             Repo.query!(
               """
               SELECT dashboard_creation_token
               FROM events
               WHERE id IN ($1, $2)
               ORDER BY id
               """,
               [first.id, second.id]
             ).rows
  end

  test "a valid UUID token persists and loads unchanged" do
    event = create_event()
    token = Ecto.UUID.generate()

    set_creation_token!(event, token)

    assert Map.fetch!(Repo.get!(Event, event.id), :dashboard_creation_token) == token
  end

  test "Postgres rejects a duplicate non-null dashboard creation token" do
    first = create_event()
    second = create_event()
    token = Ecto.UUID.generate()

    set_creation_token!(first, token)

    assert_raise Postgrex.Error, ~r/events_dashboard_creation_token_uidx/, fn ->
      set_creation_token!(second, token)
    end
  end

  test "different valid dashboard creation tokens coexist" do
    first = create_event()
    second = create_event()
    first_token = Ecto.UUID.generate()
    second_token = Ecto.UUID.generate()

    set_creation_token!(first, first_token)
    set_creation_token!(second, second_token)

    assert Map.fetch!(Repo.get!(Event, first.id), :dashboard_creation_token) == first_token
    assert Map.fetch!(Repo.get!(Event, second.id), :dashboard_creation_token) == second_token
  end

  test "the token index is unique btree on the token with the exact non-null predicate" do
    assert [
             [
               true,
               true,
               true,
               1,
               "dashboard_creation_token",
               "(dashboard_creation_token IS NOT NULL)"
             ]
           ] =
             Repo.query!(
               """
               SELECT index_state.indisunique,
                      index_state.indisready,
                      index_state.indisvalid,
                      index_state.indnkeyatts,
                      pg_get_indexdef(index_state.indexrelid, 1, true),
                      pg_get_expr(index_state.indpred, index_state.indrelid)
               FROM pg_index AS index_state
               JOIN pg_class AS index_table ON index_table.oid = index_state.indexrelid
               JOIN pg_namespace AS index_schema ON index_schema.oid = index_table.relnamespace
               JOIN pg_am AS access_method ON access_method.oid = index_table.relam
               WHERE index_schema.nspname = 'public'
                 AND index_table.relname = $1
                 AND access_method.amname = 'btree'
               """,
               ["events_dashboard_creation_token_uidx"]
             ).rows
  end

  defp set_creation_token!(event, token) do
    {:ok, dumped_token} = Ecto.UUID.dump(token)

    Repo.query!(
      "UPDATE events SET dashboard_creation_token = $1 WHERE id = $2",
      [dumped_token, event.id]
    )
  end
end
