defmodule FastCheck.Sales.CheckoutExpiryTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query
  import ExUnit.CaptureLog

  require Ash.Query

  alias Ash.Query
  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.CheckoutExpiry
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.Payments.PaymentVerification
  alias FastCheck.Sales.Payments.TestSupport, as: PaySupport
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures
  alias FastCheck.Workers.CheckoutExpirySweeperWorker
  alias FastCheck.Workers.CheckoutExpiryWorker
  alias FastCheckWeb.SalesWebFixtures, as: WebFixtures

  setup do
    offer = Fixtures.insert_offer!(configured_quantity_available: 10)
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer}
  end

  test "list_expiry_candidates includes hold_attached expired sessions only", %{offer: offer} do
    {_order, session} = checkout_with_expiry!(offer, minutes_ago: 5)

    future_session = checkout_with_expiry!(offer, minutes_ahead: 30) |> elem(1)
    _future_id = future_session.id

    ids = CheckoutExpiry.list_expiry_candidates(limit: 50)
    assert session.id in ids
    refute future_session.id in ids
  end

  test "sweeper enqueues bounded worker jobs for expired eligible sessions", %{offer: offer} do
    {_order, session} = checkout_with_expiry!(offer, minutes_ago: 5)

    assert {:ok, %{enqueued: 1, candidate_count: 1}} = CheckoutExpiry.sweep_and_enqueue(limit: 10)

    assert_enqueued(
      worker: CheckoutExpiryWorker,
      args: %{"checkout_session_id" => session.id}
    )
  end

  test "expire_session releases redis hold and marks session and order expired", %{offer: offer} do
    {order, session} = checkout_with_expiry!(offer, minutes_ago: 5)

    assert {:ok, before} = ReservationLedger.get_availability(offer.id)
    assert before.reserved_quantity == 1

    assert {:ok, :expired} = CheckoutExpiry.expire_session(session.id)

    assert {:ok, after_snapshot} = ReservationLedger.get_availability(offer.id)
    assert after_snapshot.reserved_quantity == 0

    session = reload_session!(session.id)
    order = reload_order!(order.id)

    assert session.status == "expired"
    assert order.status == "expired"
    assert not is_nil(session.expired_at)
  end

  test "duplicate expire_session calls are idempotent", %{offer: offer} do
    {_order, session} = checkout_with_expiry!(offer, minutes_ago: 5)

    assert {:ok, :expired} = CheckoutExpiry.expire_session(session.id)
    assert {:ok, :skipped_terminal} = CheckoutExpiry.expire_session(session.id)

    assert {:ok, snapshot} = ReservationLedger.get_availability(offer.id)
    assert snapshot.reserved_quantity == 0
  end

  test "release already_released still completes durable expiry when eligible", %{offer: offer} do
    {order, session} = checkout_with_expiry!(offer, minutes_ago: 5)

    assert {:ok, _} =
             ReservationLedger.release(
               offer.id,
               order.public_reference,
               "test:pre-release:#{session.id}"
             )

    assert {:ok, :expired} = CheckoutExpiry.expire_session(session.id)
    assert reload_session!(session.id).status == "expired"
  end

  test "release hold_expired still completes durable expiry when eligible", %{offer: offer} do
    {order, session} = checkout_with_expiry!(offer, minutes_ago: 5)

    on_exit(fn -> Application.delete_env(:fastcheck, :checkout_expiry_release_fun) end)

    Application.put_env(
      :fastcheck,
      :checkout_expiry_release_fun,
      fn _offer_id, _ref, _key -> {:error, :hold_expired, %{offer_id: offer.id}} end
    )

    assert {:ok, :expired} = CheckoutExpiry.expire_session(session.id)
    assert reload_order!(order.id).status == "expired"
  end

  test "ledger_unavailable leaves session and order non-expired", %{offer: offer} do
    {_order, session} = checkout_with_expiry!(offer, minutes_ago: 5)

    on_exit(fn -> Application.delete_env(:fastcheck, :checkout_expiry_release_fun) end)

    Application.put_env(
      :fastcheck,
      :checkout_expiry_release_fun,
      fn _offer_id, _ref, _key -> {:error, :ledger_unavailable, %{reason: "test"}} end
    )

    assert {:error, :ledger_unavailable} = CheckoutExpiry.expire_session(session.id)

    session = reload_session!(session.id)
    assert session.status == "hold_attached"
    refute session.expired_at
  end

  test "verified_success payment before cleanup skips expiry and release", %{offer: offer} do
    paystack_cleanup = PaySupport.setup_paystack!()

    %{order: order, session: session, attempt: attempt} =
      PaySupport.initialized_payment!(offer)

    set_expires_at!(session.id, minutes_ago: 5)

    Repo.update_all(
      from(pa in "sales_payment_attempts", where: pa.id == ^attempt.id),
      set: [status: "verified_success"]
    )

    assert {:ok, :skipped_verified} = CheckoutExpiry.expire_session(session.id)

    assert reload_session!(session.id).status == "payment_link_sent"
    assert reload_order!(order.id).status == "awaiting_payment"

    assert {:ok, snapshot} = ReservationLedger.get_availability(offer.id)
    assert snapshot.reserved_quantity == 1

    paystack_cleanup.()
  end

  test "payment verification after automated expiry stays VS-07C safe without tickets", %{
    offer: offer
  } do
    paystack_cleanup = PaySupport.setup_paystack!()

    %{order: order, session: session, attempt: attempt} =
      PaySupport.initialized_payment!(offer)

    set_expires_at!(session.id, minutes_ago: 5)
    assert {:ok, :expired} = CheckoutExpiry.expire_session(session.id)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      PaySupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    assert {:ok, :manual_review} = PaymentVerification.verify_attempt(attempt.id)

    order = reload_order!(order.id)
    session = reload_session!(session.id)
    attempt = reload_attempt!(attempt.id)

    assert attempt.status == "verified_success"
    assert order.status == "manual_review"
    assert session.status == "manual_review"
    assert Repo.aggregate("sales_ticket_issues", :count, :id) == 0

    paystack_cleanup.()
  end

  test "race: verification success wins over expiry when payment verifies first", %{offer: offer} do
    paystack_cleanup = PaySupport.setup_paystack!()

    %{order: order, session: session, attempt: attempt} =
      PaySupport.initialized_payment!(offer)

    set_expires_at!(session.id, minutes_ago: 5)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      PaySupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)
    assert {:ok, :skipped_terminal} = CheckoutExpiry.expire_session(session.id)

    order = reload_order!(order.id)
    session = reload_session!(session.id)

    assert order.status == "paid_verified"
    assert session.status == "paid"

    paystack_cleanup.()
  end

  test "hold anomaly routes to manual_review instead of silent expire", %{offer: offer} do
    {order, session} = checkout_with_expiry!(offer, minutes_ago: 5)

    Repo.update_all(
      from(cs in "sales_checkout_sessions", where: cs.id == ^session.id),
      set: [redis_hold_key: nil]
    )

    assert {:ok, :manual_review} = CheckoutExpiry.expire_session(session.id)

    order = reload_order!(order.id)
    session = reload_session!(session.id)

    assert order.status == "manual_review"
    assert session.status == "manual_review"
    assert order.manual_review_reason == "checkout_expiry_hold_state_mismatch"
  end

  test "expire_session uses order-level advisory lock like payment verification" do
    source = File.read!("lib/fastcheck/sales/checkout_expiry.ex")
    assert source =~ "pg_advisory_xact_lock"
    assert source =~ "reload_session!"
    assert source =~ "reload_order!"
  end

  test "logs avoid buyer email and payment secrets", %{offer: offer} do
    {_order, session} = checkout_with_expiry!(offer, minutes_ago: 5)

    log =
      capture_log(fn ->
        assert {:ok, :expired} = CheckoutExpiry.expire_session(session.id)
      end)

    refute log =~ "buyer@example.com"
    refute log =~ "AC_SAFE"
    refute log =~ "checkout.paystack.com"
  end

  test "sweeper worker delegates to CheckoutExpiry", %{offer: offer} do
    {_order, session} = checkout_with_expiry!(offer, minutes_ago: 5)

    assert :ok = perform_job(CheckoutExpirySweeperWorker, %{})

    assert_enqueued(
      worker: CheckoutExpiryWorker,
      args: %{"checkout_session_id" => session.id}
    )
  end

  test "expire does not bump event_sync_version" do
    event = WebFixtures.insert_event!()
    offer = Fixtures.insert_offer!(event_id: event.id, configured_quantity_available: 10)
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    {order, session} = checkout_with_expiry!(offer, minutes_ago: 5)
    before = event_sync_version(order.event_id)

    assert {:ok, :expired} = CheckoutExpiry.expire_session(session.id)
    assert event_sync_version(order.event_id) == before
  end

  defp checkout_with_expiry!(offer, opts) do
    input =
      Fixtures.checkout_input(%{
        event_id: offer.event_id,
        ticket_offer_id: offer.id,
        idempotency_key: "expiry-#{System.unique_integer([:positive])}"
      })

    {:ok, %{order: order, checkout_session: session}} =
      Checkout.start_checkout(input, Fixtures.system_actor([offer.event_id]),
        effective_sales_channel: "whatsapp"
      )

    minutes_ago = Keyword.get(opts, :minutes_ago)
    minutes_ahead = Keyword.get(opts, :minutes_ahead)

    cond do
      minutes_ago ->
        set_expires_at!(session.id, minutes_ago: minutes_ago)

      minutes_ahead ->
        set_expires_at!(session.id, minutes_ahead: minutes_ahead)

      true ->
        :ok
    end

    {reload_order!(order.id), reload_session!(session.id)}
  end

  defp set_expires_at!(session_id, opts) do
    dt =
      cond do
        minutes_ago = Keyword.get(opts, :minutes_ago) ->
          DateTime.utc_now()
          |> DateTime.add(-minutes_ago * 60, :second)
          |> DateTime.truncate(:second)

        minutes_ahead = Keyword.get(opts, :minutes_ahead) ->
          DateTime.utc_now()
          |> DateTime.add(minutes_ahead * 60, :second)
          |> DateTime.truncate(:second)
      end

    Repo.update_all(
      from(cs in "sales_checkout_sessions", where: cs.id == ^session_id),
      set: [expires_at: dt]
    )
  end

  defp reload_session!(id) do
    CheckoutSession
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp reload_order!(id) do
    Order
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp reload_attempt!(id) do
    PaymentAttempt
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp event_sync_version(event_id) do
    Repo.one!(from(e in Event, where: e.id == ^event_id, select: e.event_sync_version))
  end
end
