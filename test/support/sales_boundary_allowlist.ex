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

  @vs_07a_allowed_prefixes [
    "lib/fastcheck_web/controllers/webhooks/paystack_controller.ex",
    "lib/fastcheck_web/plugs/raw_body_reader.ex",
    "lib/fastcheck_web/endpoint.ex",
    "test/fastcheck_web/controllers/webhooks/",
    "docs/fastcheck_sales/slices/VS-07A_PAYSTACK_WEBHOOK_INGESTION.md"
  ]

  @vs_12_allowed_prefixes [
    "lib/fastcheck_web/live/sales_dashboard_live.ex"
  ]

  @vs_13_allowed_prefixes [
    "config/config.exs",
    "lib/fastcheck/sales.ex",
    "lib/fastcheck/sales/manual_review.ex",
    "lib/fastcheck/sales/manual_review_action.ex",
    "lib/fastcheck/sales/order.ex",
    "lib/fastcheck/sales/payment_attempt.ex",
    "lib/fastcheck/tickets/issuer.ex",
    "lib/fastcheck/workers/issue_tickets_worker.ex",
    "lib/fastcheck_web/live/sales_manual_review_live.ex",
    "lib/fastcheck_web/router.ex",
    "priv/repo/migrations/",
    "test/fastcheck/sales/",
    "test/fastcheck/workers/",
    "test/fastcheck_web/sales_manual_review_live_test.exs",
    "test/support/sales_boundary_allowlist.ex"
  ]

  @vs_15b_allowed_prefixes [
    "lib/fastcheck/sales/admin_refunds.ex",
    "lib/fastcheck/sales/admin_revocations.ex",
    "lib/fastcheck/sales/order.ex",
    "lib/fastcheck/observability/telemetry_names.ex",
    "lib/fastcheck_web/live/sales/",
    "lib/fastcheck_web/live/sales_dashboard_live.ex",
    "lib/fastcheck_web/router.ex",
    "test/fastcheck/sales/admin_refunds_test.exs",
    "test/fastcheck/sales/admin_revocations_test.exs",
    "test/fastcheck_web/live/sales/order_show_live_test.exs",
    "test/fastcheck/observability/telemetry_names_test.exs",
    "test/fastcheck/sales/domain_shell_test.exs",
    "test/support/admin_refund_fixtures.ex",
    "test/support/sales_boundary_allowlist.ex"
  ]

  @vs_17_allowed_prefixes [
    "config/config.exs",
    "config/runtime.exs",
    "lib/fastcheck/messaging/whatsapp/",
    "lib/fastcheck/sales/conversation.ex",
    "lib/fastcheck/workers/whatsapp_inbound_worker.ex",
    "lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex",
    "lib/fastcheck_web/endpoint.ex",
    "lib/fastcheck_web/plugs/rate_limiter.ex",
    "lib/fastcheck_web/plugs/raw_body_reader.ex",
    "lib/fastcheck_web/router.ex",
    "test/fastcheck/messaging/whatsapp/",
    "test/fastcheck/workers/whatsapp_inbound_worker_test.exs",
    "test/fastcheck_web/controllers/webhooks/whatsapp_controller_test.exs",
    "test/support/whatsapp_webhook_test_support.ex",
    "test/support/sales_boundary_allowlist.ex"
  ]

  @vs_18_allowed_prefixes [
    "lib/fastcheck/messaging/whatsapp/",
    "lib/fastcheck/sales/conversation.ex",
    "lib/fastcheck/sales/ticket_offer.ex",
    "lib/fastcheck/workers/whatsapp_inbound_worker.ex",
    "lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex",
    "test/fastcheck/messaging/whatsapp/",
    "test/fastcheck/sales/conversation_resource_skeleton_test.exs",
    "test/fastcheck/sales/conversation_state_actions_test.exs",
    "test/fastcheck/sales/vs_01e_boundary_test.exs",
    "test/fastcheck/workers/whatsapp_inbound_worker_test.exs",
    "test/support/sales_boundary_allowlist.ex"
  ]

  @vs_21b_allowed_prefixes [
    "lib/fastcheck/sales/audit_views.ex",
    "lib/fastcheck/sales/ops_metrics.ex",
    "lib/fastcheck_web/live/sales/audit_timeline_live.ex",
    "lib/fastcheck_web/live/sales/ops_dashboard_live.ex",
    "lib/fastcheck_web/router.ex",
    "lib/fastcheck_web/telemetry.ex",
    "priv/repo/migrations/",
    "test/fastcheck/sales/audit_views_test.exs",
    "test/fastcheck/sales/ops_metrics_test.exs",
    "test/fastcheck_web/live/sales/audit_timeline_live_test.exs",
    "test/fastcheck_web/live/sales/ops_dashboard_live_test.exs",
    "test/fastcheck_web/telemetry_sales_metrics_test.exs",
    "test/fastcheck/sales/domain_shell_test.exs",
    "test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs",
    "test/support/sales_boundary_allowlist.ex"
  ]

  @vs_24c_allowed_prefixes [
    "lib/fastcheck/tickets/artifact_resolver.ex",
    "lib/fastcheck_web/controllers/sales/ticket_pdf_controller.ex",
    "lib/fastcheck_web/live/sales/order_show_live.ex",
    "lib/fastcheck_web/router.ex",
    "test/fastcheck/tickets/artifact_resolver_test.exs",
    "test/fastcheck_web/controllers/sales/ticket_pdf_controller_test.exs",
    "test/fastcheck_web/live/sales/order_show_live_test.exs",
    "test/support/sales_boundary_allowlist.ex"
  ]

  @vs_24d_a_allowed_prefixes [
    "config/config.exs",
    "config/test.exs",
    "lib/fastcheck/sales.ex",
    "lib/fastcheck/sales/ticket_resend_challenge.ex",
    "lib/fastcheck/tickets/resend/",
    "priv/repo/migrations/20260702093815_create_sales_ticket_resend_challenges.exs",
    "test/fastcheck/sales/ticket_resend_challenge_test.exs",
    "test/fastcheck/tickets/resend/",
    "test/support/ticket_resend_fixtures.ex",
    "test/support/sales_boundary_allowlist.ex"
  ]

  @doc false
  def vs_05a_allowed_change?(file) when is_binary(file) do
    Enum.any?(@vs_05a_allowed_prefixes, fn allowed ->
      file == allowed or String.starts_with?(file, allowed)
    end)
  end

  @doc false
  def vs_07a_allowed_change?(file) when is_binary(file) do
    Enum.any?(@vs_07a_allowed_prefixes, fn allowed ->
      file == allowed or String.starts_with?(file, allowed)
    end)
  end

  @doc false
  def reject_forbidden_changed_file?(file, forbidden_prefix) do
    String.starts_with?(file, forbidden_prefix) and not allowed_change?(file)
  end

  defp allowed_change?(file) do
    vs_05a_allowed_change?(file) or vs_07a_allowed_change?(file) or
      Enum.member?(@vs_12_allowed_prefixes, file) or vs_13_allowed_change?(file) or
      vs_15b_allowed_change?(file) or vs_17_allowed_change?(file) or
      vs_18_allowed_change?(file) or vs_21b_allowed_change?(file) or
      vs_24c_allowed_change?(file) or vs_24d_a_allowed_change?(file)
  end

  defp vs_24d_a_allowed_change?(file) do
    Enum.any?(@vs_24d_a_allowed_prefixes, fn allowed ->
      file == allowed or String.starts_with?(file, allowed)
    end)
  end

  defp vs_24c_allowed_change?(file) do
    Enum.any?(@vs_24c_allowed_prefixes, fn allowed ->
      file == allowed or String.starts_with?(file, allowed)
    end)
  end

  defp vs_21b_allowed_change?(file) do
    Enum.any?(@vs_21b_allowed_prefixes, fn allowed ->
      file == allowed or String.starts_with?(file, allowed)
    end)
  end

  defp vs_18_allowed_change?(file) do
    Enum.any?(@vs_18_allowed_prefixes, fn allowed ->
      file == allowed or String.starts_with?(file, allowed)
    end)
  end

  defp vs_17_allowed_change?(file) do
    Enum.any?(@vs_17_allowed_prefixes, fn allowed ->
      file == allowed or String.starts_with?(file, allowed)
    end)
  end

  defp vs_15b_allowed_change?(file) do
    Enum.any?(@vs_15b_allowed_prefixes, fn allowed ->
      file == allowed or String.starts_with?(file, allowed)
    end)
  end

  defp vs_13_allowed_change?(file) do
    Enum.any?(@vs_13_allowed_prefixes, fn allowed ->
      file == allowed or String.starts_with?(file, allowed)
    end)
  end
end
