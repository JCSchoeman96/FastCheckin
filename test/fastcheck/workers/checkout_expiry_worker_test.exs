defmodule FastCheck.Workers.CheckoutExpiryWorkerTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias FastCheck.SalesCheckoutFixtures, as: Fixtures
  alias FastCheck.Workers.CheckoutExpiryWorker

  setup do
    offer = Fixtures.insert_offer!(configured_quantity_available: 10)
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer}
  end

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

  test "worker does not crash on unknown release error", %{offer: offer} do
    session = checkout_session_expired!(offer)

    on_exit(fn -> Application.delete_env(:fastcheck, :checkout_expiry_release_fun) end)

    Application.put_env(
      :fastcheck,
      :checkout_expiry_release_fun,
      fn _offer_id, _ref, _key -> {:error, :unknown_ledger_state, %{}} end
    )

    assert {:error, :unknown_ledger_state} =
             perform_job(CheckoutExpiryWorker, %{"checkout_session_id" => session.id})
  end

  defp checkout_session_expired!(offer) do
    input =
      Fixtures.checkout_input(%{
        event_id: offer.event_id,
        ticket_offer_id: offer.id,
        idempotency_key: "worker-expiry-#{System.unique_integer([:positive])}"
      })

    {:ok, %{checkout_session: session}} =
      FastCheck.Sales.Checkout.start_checkout(input, Fixtures.system_actor([offer.event_id]),
        effective_sales_channel: "whatsapp"
      )

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(-5 * 60, :second)
      |> DateTime.truncate(:second)

    FastCheck.Repo.update_all(
      Ecto.Query.from(cs in "sales_checkout_sessions", where: cs.id == ^session.id),
      set: [expires_at: expires_at]
    )

    session
  end
end
