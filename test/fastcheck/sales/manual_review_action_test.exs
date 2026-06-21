defmodule FastCheck.Sales.ManualReviewActionTest do
  use FastCheck.DataCase, async: false

  alias Ash.Changeset
  alias FastCheck.Repo
  alias FastCheck.Sales.ManualReviewAction

  test "manual review actions table has bounded audit columns and indexes" do
    assert_table("sales_manual_review_actions")

    assert_columns("sales_manual_review_actions", [
      "id",
      "subject_type",
      "subject_id",
      "sales_order_id",
      "payment_attempt_id",
      "payment_event_id",
      "ticket_issue_id",
      "checkout_session_id",
      "action",
      "reason_code",
      "note",
      "actor_type",
      "actor_id",
      "actor_label",
      "previous_status",
      "new_status",
      "metadata",
      "correlation_id",
      "inserted_at"
    ])

    assert_index("sales_manual_review_actions_subject_idx", [
      "subject_type",
      "subject_id",
      "inserted_at"
    ])

    assert_index("sales_manual_review_actions_order_idx", ["sales_order_id", "inserted_at"])
    assert_index("sales_manual_review_actions_actor_idx", ["actor_id", "inserted_at"])
    assert_index("sales_manual_review_actions_action_idx", ["action", "inserted_at"])
  end

  test "resource records append-only sanitized audit actions" do
    attrs = %{
      subject_type: "order",
      subject_id: "101",
      sales_order_id: 101,
      action: "add_note",
      reason_code: "operator_note",
      note: "review note",
      actor_type: "dashboard_user",
      actor_id: "admin",
      actor_label: "admin",
      previous_status: "manual_review",
      new_status: "manual_review",
      metadata: %{
        "order_id" => 101,
        "buyer_email" => "secret@example.com",
        "raw_payload" => %{"secret" => true},
        "access_code" => "ACCESS_SECRET"
      }
    }

    assert {:ok, action} =
             ManualReviewAction
             |> Changeset.for_create(:record_action, attrs,
               actor: %{actor_type: :admin, actor_id: "admin"}
             )
             |> Ash.create()

    refute action.metadata["buyer_email"] == "secret@example.com"
    refute action.metadata["raw_payload"] == %{"secret" => true}
    refute action.metadata["access_code"] == "ACCESS_SECRET"

    update_actions = ManualReviewAction |> Ash.Resource.Info.actions() |> Enum.map(& &1.name)
    refute :update in update_actions
    refute :destroy in update_actions
  end

  defp assert_table(table) do
    assert %{num_rows: 1} =
             Repo.query!(
               "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
               [table]
             )
  end

  defp assert_columns(table, columns) do
    result =
      Repo.query!(
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1
        """,
        [table]
      )

    actual = Enum.map(result.rows, &List.first/1)

    for column <- columns do
      assert column in actual
    end
  end

  defp assert_index(index_name, expected_columns) do
    result =
      Repo.query!(
        """
        SELECT a.attname
        FROM pg_class i
        JOIN pg_index ix ON ix.indexrelid = i.oid
        JOIN pg_class t ON t.oid = ix.indrelid
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
        WHERE i.relname = $1
        ORDER BY array_position(ix.indkey, a.attnum)
        """,
        [index_name]
      )

    assert Enum.map(result.rows, &List.first/1) == expected_columns
  end
end
