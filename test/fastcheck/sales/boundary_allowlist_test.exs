defmodule FastCheck.Sales.BoundaryAllowlistTest do
  use ExUnit.Case, async: true

  alias FastCheck.Sales.BoundaryAllowlist

  test "ordinary test runs leave branch-diff enforcement disabled" do
    command = fn _executable, _arguments ->
      flunk("git must not run without explicit configuration")
    end

    assert :disabled =
             BoundaryAllowlist.changed_files_for_slice("VS-01E",
               environment: %{},
               command: command
             )
  end

  test "only the explicitly selected slice diffs from the explicit base SHA" do
    command = fn "git", ["diff", "--name-only", "abc123...HEAD"] ->
      {"android/scanner-app/app/build.gradle.kts\nlib/fastcheck/sales/order.ex\n", 0}
    end

    environment = %{
      "FASTCHECK_SLICE_BOUNDARY" => "VS-01E",
      "FASTCHECK_BOUNDARY_BASE_SHA" => "abc123"
    }

    assert {:enabled,
            ["android/scanner-app/app/build.gradle.kts", "lib/fastcheck/sales/order.ex"]} =
             BoundaryAllowlist.changed_files_for_slice("VS-01E",
               environment: environment,
               command: command
             )

    assert :disabled =
             BoundaryAllowlist.changed_files_for_slice("VS-01F",
               environment: environment,
               command: command
             )
  end

  test "an explicit slice without a base SHA fails closed" do
    assert_raise ArgumentError, ~r/FASTCHECK_BOUNDARY_BASE_SHA/, fn ->
      BoundaryAllowlist.changed_files_for_slice("VS-01E",
        environment: %{"FASTCHECK_SLICE_BOUNDARY" => "VS-01E"}
      )
    end
  end

  test "an unknown explicit slice fails closed" do
    assert_raise ArgumentError, ~r/unknown FASTCHECK_SLICE_BOUNDARY/, fn ->
      BoundaryAllowlist.changed_files_for_slice("VS-01E",
        environment: %{
          "FASTCHECK_SLICE_BOUNDARY" => "VS-UNKNOWN",
          "FASTCHECK_BOUNDARY_BASE_SHA" => "abc123"
        }
      )
    end
  end

  test "a failed explicit git diff fails closed" do
    command = fn "git", ["diff", "--name-only", "missing...HEAD"] ->
      {"fatal: bad revision", 128}
    end

    assert_raise RuntimeError, ~r/git diff failed/, fn ->
      BoundaryAllowlist.changed_files_for_slice("VS-09B",
        environment: %{
          "FASTCHECK_SLICE_BOUNDARY" => "VS-09B",
          "FASTCHECK_BOUNDARY_BASE_SHA" => "missing"
        },
        command: command
      )
    end
  end
end
