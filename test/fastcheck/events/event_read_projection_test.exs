defmodule FastCheck.Events.EventReadProjectionTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Events
  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias FastCheckWeb.SalesWebFixtures, as: WebFixtures

  test "WhatsApp and lifecycle fallback reads select only fields used by their branches" do
    enabled_event = create_event(%{name: "Projection enable"})

    assert {:ok, %Event{whatsapp_sales_enabled: true}} =
             Events.enable_whatsapp_sales(enabled_event.id)

    {enabled_result, enabled_queries} =
      capture_repo_queries(fn -> Events.enable_whatsapp_sales(enabled_event.id) end)

    assert {:ok, %Event{whatsapp_sales_enabled: true}} = enabled_result
    assert_fallback_projection(enabled_queries, [:id, :status, :whatsapp_sales_enabled])

    disabled_event = create_event(%{name: "Projection disable"})

    {disabled_result, disabled_queries} =
      capture_repo_queries(fn -> Events.disable_whatsapp_sales(disabled_event.id) end)

    assert {:ok, %Event{whatsapp_sales_enabled: false}} = disabled_result
    assert_fallback_projection(disabled_queries, [:id, :whatsapp_sales_enabled])

    quantity_event = create_event(%{name: "Projection quantity cap"})
    actor = WebFixtures.dashboard_actor([quantity_event.id])

    {quantity_result, quantity_queries} =
      capture_repo_queries(fn ->
        Events.set_whatsapp_max_tickets_per_order(actor, quantity_event.id, 9)
      end)

    assert {:ok, %Event{whatsapp_max_tickets_per_order: 9}} = quantity_result

    assert_fallback_projection(quantity_queries, [
      :id,
      :status,
      :whatsapp_max_tickets_per_order
    ])

    archived_event = create_event(%{name: "Projection archive", status: "archived"})

    {archive_result, archive_queries} =
      capture_repo_queries(fn -> Events.archive_event(archived_event.id) end)

    assert {:ok, %Event{status: "archived", whatsapp_sales_enabled: false}} = archive_result

    assert_fallback_projection(archive_queries, [
      :id,
      :status,
      :whatsapp_sales_enabled
    ])

    active_event = create_event(%{name: "Projection unarchive"})

    {unarchive_result, unarchive_queries} =
      capture_repo_queries(fn -> Events.unarchive_event(active_event.id) end)

    assert {:ok, %Event{status: "active", whatsapp_sales_enabled: false}} = unarchive_result

    assert_fallback_projection(unarchive_queries, [
      :id,
      :status,
      :whatsapp_sales_enabled
    ])
  end

  defp assert_fallback_projection(queries, expected_fields) do
    selects = Enum.filter(queries, &String.starts_with?(&1, "SELECT "))
    assert [fallback_select, _return_value_select] = selects

    selected_fields =
      Regex.scan(~r/"([^"]+)"/, select_clause(fallback_select), capture: :all_but_first)
      |> List.flatten()

    assert Enum.sort(selected_fields) == Enum.sort(Enum.map(expected_fields, &Atom.to_string/1))
  end

  defp select_clause(query) do
    [_, columns] = Regex.run(~r/\ASELECT (.+?) FROM /, query)
    columns
  end

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    ref = make_ref()
    handler_id = "event-projection-test-#{System.unique_integer([:positive])}"
    parent = self()
    event_name = (Repo.config()[:telemetry_prefix] || [:fastcheck, :repo]) ++ [:query]

    :telemetry.attach(
      handler_id,
      event_name,
      fn _event, _measurements, metadata, _config ->
        send(parent, {:repo_query, ref, metadata.query})
      end,
      nil
    )

    result = fun.()
    queries = drain_repo_queries(ref, [])
    :telemetry.detach(handler_id)

    {result, queries}
  end

  defp drain_repo_queries(ref, queries) do
    receive do
      {:repo_query, ^ref, query} -> drain_repo_queries(ref, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
