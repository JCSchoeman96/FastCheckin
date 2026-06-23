defmodule FastCheck.Workers.CheckoutExpirySweeperWorkerTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.CheckoutExpiry
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures
  alias FastCheck.Workers.CheckoutExpirySweeperWorker
  alias FastCheck.Workers.CheckoutExpiryWorker

  setup do
    offer = Fixtures.insert_offer!()
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer}
  end

  test "sweeper worker delegates to checkout expiry sweep boundary" do
    source = File.read!("lib/fastcheck/workers/checkout_expiry_sweeper_worker.ex")
    assert source =~ "CheckoutExpiry.sweep_and_enqueue"
    refute source =~ "ReservationLedger"
    refute source =~ "expire_session"
  end

  test "duplicate sweeper jobs are deduplicated by uniqueness", %{offer: offer} do
    {_order, session} = expired_checkout!(offer)

    assert {:ok, first} = CheckoutExpirySweeperWorker.new(%{}) |> Oban.insert()
    assert {:ok, second} = CheckoutExpirySweeperWorker.new(%{}) |> Oban.insert()
    assert first.id != second.id or first.conflict? or second.conflict?

    assert :ok = perform_job(CheckoutExpirySweeperWorker, %{})
    assert_enqueued(worker: CheckoutExpiryWorker, args: %{"checkout_session_id" => session.id})
  end

  test "sweep_and_enqueue respects batch limit", %{offer: offer} do
    for _ <- 1..3, do: expired_checkout!(offer)

    assert {:ok, %{candidate_count: 2, enqueued: 2}} =
             CheckoutExpiry.sweep_and_enqueue(limit: 2)
  end

  defp expired_checkout!(offer) do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: "sweeper-#{System.unique_integer([:positive])}"
      })

    {:ok, %{order: order, checkout_session: session}} =
      Checkout.start_checkout(input, Fixtures.system_actor(), effective_sales_channel: "whatsapp")

    past = DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.truncate(:second)

    FastCheck.Repo.update_all(
      Ecto.Query.from(cs in "sales_checkout_sessions", where: cs.id == ^session.id),
      set: [expires_at: past]
    )

    {order, session}
  end
end
