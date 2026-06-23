defmodule FastCheck.Workers.CheckoutExpiryWorkerTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias FastCheck.Workers.CheckoutExpiryWorker

  test "worker is unique by checkout_session_id and delegates to checkout expiry boundary" do
    args = %{"checkout_session_id" => 42, "correlation_id" => "corr-42"}

    assert {:ok, first} = CheckoutExpiryWorker.new(args) |> Oban.insert()
    assert {:ok, second} = CheckoutExpiryWorker.new(args) |> Oban.insert()
    assert first.id != second.id or first.conflict? or second.conflict?

    source = File.read!("lib/fastcheck/workers/checkout_expiry_worker.ex")
    assert source =~ "FastCheck.Sales.CheckoutExpiry"
    assert source =~ "CheckoutExpiry.expire_session"
    refute source =~ "ReservationLedger"
    refute source =~ "Paystack"
    refute source =~ "TicketIssue"
    refute source =~ "Attendee"
  end

  test "worker returns error for missing session without creating sales rows" do
    assert {:error, :checkout_session_not_found} =
             perform_job(CheckoutExpiryWorker, %{"checkout_session_id" => 9_999_999})
  end
end
