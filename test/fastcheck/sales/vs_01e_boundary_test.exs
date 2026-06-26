defmodule FastCheck.Sales.Vs01eBoundaryTest do
  use ExUnit.Case, async: true

  @forbidden_paths [
    "lib/fastcheck/workers/verify_payment_worker.ex",
    "lib/fastcheck/workers/delivery_attempt_worker.ex",
    "lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex"
  ]

  @forbidden_action_modules [
    {FastCheck.Sales.Conversation, :start_or_resume},
    {FastCheck.Sales.Conversation, :select_language},
    {FastCheck.Sales.Conversation, :confirm_order},
    {FastCheck.Sales.Conversation, :mark_payment_pending},
    {FastCheck.Sales.Conversation, :mark_ticket_issued},
    {FastCheck.Sales.Conversation, :expire_conversation}
  ]

  test "forbidden runtime paths remain absent in VS-01E" do
    for path <- @forbidden_paths do
      refute File.exists?(path), "#{path} is out of scope for VS-01E"
    end

    assert Path.wildcard("lib/fastcheck/workers/*delivery*") == []
  end

  test "forbidden workflow actions are not implemented in VS-01E" do
    for {resource, action_name} <- @forbidden_action_modules do
      refute Ash.Resource.Info.action(resource, action_name),
             "#{inspect(resource)} must not expose #{inspect(action_name)} in VS-01E"
    end
  end

  test "existing scanner, mobile, event, attendee, Tickera, and Android surfaces remain untouched" do
    changed_files =
      System.cmd("git", ["diff", "--name-only", "main...HEAD"])
      |> elem(0)
      |> String.split("\n", trim: true)

    forbidden_changed_prefixes = [
      "android/",
      "lib/fastcheck/ticketing/",
      "lib/fastcheck_web/controllers/",
      "lib/fastcheck_web/live/",
      "lib/fastcheck_web/router.ex"
    ]

    for file <- changed_files,
        prefix <- forbidden_changed_prefixes,
        FastCheck.Sales.BoundaryAllowlist.reject_forbidden_changed_file?(file, prefix) do
      flunk("#{file} must not change in VS-01E")
    end
  end
end
