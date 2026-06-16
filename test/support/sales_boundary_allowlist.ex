defmodule FastCheck.Sales.BoundaryAllowlist do
  @moduledoc false

  @vs_05a_allowed_prefixes [
    "lib/fastcheck/sales/secondary_entrypoints.ex",
    "lib/fastcheck_web/live/sales/",
    "lib/fastcheck_web/router.ex",
    "config/config.exs",
    "config/runtime.exs",
    "config/test.exs",
    "test/fastcheck/sales/secondary_entrypoints_test.exs",
    "test/fastcheck_web/sales/",
    "test/support/sales_web_fixtures.ex",
    "docs/fastcheck_sales/slices/VS-05A_SECONDARY_SALES_ENTRY_POINTS.md",
    ".cursor/plans/vs-05a-secondary-sales-entry-points.plan.md"
  ]

  @doc false
  def vs_05a_allowed_change?(file) when is_binary(file) do
    Enum.any?(@vs_05a_allowed_prefixes, fn allowed ->
      file == allowed or String.starts_with?(file, allowed)
    end)
  end

  @doc false
  def reject_forbidden_changed_file?(file, forbidden_prefix) do
    String.starts_with?(file, forbidden_prefix) and not vs_05a_allowed_change?(file)
  end
end
