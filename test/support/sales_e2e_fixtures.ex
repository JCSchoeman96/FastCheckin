defmodule FastCheck.SalesE2EFixtures do
  @moduledoc false

  import Ecto.Query

  require Ash.Query

  alias Ash.Query
  alias FastCheck.Crypto
  alias FastCheck.Events.Event
  alias FastCheck.Mobile.Token
  alias FastCheck.Repo
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.DeliveryAttempt
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.PaymentEvent
  alias FastCheck.Sales.Payments.TestSupport, as: PaystackSupport
  alias FastCheck.Sales.Payments.TransactionInitialization
  alias FastCheck.Sales.Payments.WebhookIngestion
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.SalesCheckoutFixtures
  alias FastCheck.TestSupport.Scans.InMemoryStore
  alias FastCheckWeb.SalesWebFixtures

  def setup_sales_event_offer!(opts \\ []) do
    channel = Keyword.get(opts, :sales_channel, "whatsapp")
    configured = Keyword.get(opts, :configured_quantity_available, 10)

    event =
      SalesWebFixtures.insert_event!(%{
        name: "VS-22 Event #{System.unique_integer([:positive])}",
        scanner_login_code: unique_scanner_code()
      })

    offer =
      SalesCheckoutFixtures.insert_offer!(
        event_id: event.id,
        sales_channel: channel,
        configured_quantity_available: configured,
        max_per_order: Keyword.get(opts, :max_per_order, 5),
        name: Keyword.get(opts, :name, "VS-22 #{channel} Offer")
      )

    {event, offer}
  end

  def start_initialized_checkout!(event, offer, opts \\ []) do
    source_channel = Keyword.get(opts, :source_channel, "whatsapp")
    effective_channel = Keyword.get(opts, :effective_sales_channel, source_channel)
    quantity = Keyword.get(opts, :quantity, 1)

    input =
      SalesCheckoutFixtures.checkout_input(%{
        event_id: event.id,
        ticket_offer_id: offer.id,
        quantity: quantity,
        buyer_name: Keyword.get(opts, :buyer_name, "VS-22 Buyer"),
        buyer_phone: Keyword.get(opts, :buyer_phone, "+27821234567"),
        buyer_email: Keyword.get(opts, :buyer_email, "vs22-buyer@example.com"),
        source_channel: source_channel,
        idempotency_key: Keyword.get(opts, :idempotency_key, e2e_id("checkout")),
        correlation_id: Keyword.get(opts, :correlation_id, e2e_id("corr")),
        event_name: event.name
      })

    actor = actor_for(source_channel, event.id)

    {:ok, %{order: order, checkout_session: session}} =
      Checkout.start_checkout(input, actor, effective_sales_channel: effective_channel)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      PaystackSupport.init_and_verify_request_fun(amount: order.total_amount_cents)
    )

    {:ok, init} =
      TransactionInitialization.initialize_for_checkout_session(
        session.id,
        SalesCheckoutFixtures.system_actor([event.id])
      )

    %{
      order: reload_order!(order.id),
      session: reload_session!(session.id),
      attempt: reload_payment_attempt!(init.payment_attempt_id),
      init: init
    }
  end

  def ingest_paystack_success!(attempt, opts \\ []) do
    provider_event_id = Keyword.get(opts, :provider_event_id, e2e_id("evt"))

    body =
      PaystackSupport.charge_success_webhook_body(
        provider_event_id: provider_event_id,
        reference: attempt.provider_reference
      )

    signature = PaystackSupport.sign_webhook_body(body)

    {:ok, status, event} =
      WebhookIngestion.ingest(body, signature, correlation_id: e2e_id("webhook"))

    %{status: status, event: event, body: body, signature: signature}
  end

  def configure_mobile_scan_ingestion!(namespace \\ e2e_id("scan-live")) do
    original = Application.get_env(:fastcheck, :mobile_scan_ingestion, [])
    InMemoryStore.reset()

    Application.put_env(:fastcheck, :mobile_scan_ingestion,
      chunk_size: 100,
      live_namespace: namespace,
      store: InMemoryStore,
      force_enqueue_failure: false
    )

    fn ->
      Application.put_env(:fastcheck, :mobile_scan_ingestion, original)
      InMemoryStore.reset()
    end
  end

  def mobile_token!(event_id) do
    {:ok, token} = Token.issue_scanner_token(event_id)
    token
  end

  def scan_payload(ticket_code, opts \\ []) do
    %{
      "idempotency_key" => Keyword.get(opts, :idempotency_key, e2e_id("scan")),
      "ticket_code" => ticket_code,
      "direction" => Keyword.get(opts, :direction, "in"),
      "scanned_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "entrance_name" => Keyword.get(opts, :entrance_name, "Main Gate"),
      "operator_name" => Keyword.get(opts, :operator_name, "VS-22 Scanner")
    }
  end

  def ticket_issue_for_order!(order_id) do
    TicketIssue
    |> Query.filter(sales_order_id == ^order_id)
    |> Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  def ticket_issues_for_order(order_id) do
    TicketIssue
    |> Query.filter(sales_order_id == ^order_id)
    |> Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
  end

  def delivery_attempts_for_order(order_id) do
    DeliveryAttempt
    |> Query.filter(sales_order_id == ^order_id)
    |> Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
  end

  def reload_order!(id), do: read_one!(Order, id)
  def reload_session!(id), do: read_one!(CheckoutSession, id)
  def reload_payment_attempt!(id), do: read_one!(PaymentAttempt, id)
  def reload_payment_event!(id), do: read_one!(PaymentEvent, id)
  def reload_ticket_issue!(id), do: read_one!(TicketIssue, id)

  def checkout_session_for_order!(order_id) do
    CheckoutSession
    |> Query.filter(sales_order_id == ^order_id)
    |> Ash.read_one!(authorize?: false)
  end

  def event_sync_version(event_id) do
    Repo.one!(from e in Event, where: e.id == ^event_id, select: e.event_sync_version)
  end

  def sales_counts(order_id) do
    %{
      attendees:
        Repo.one!(
          from a in "attendees",
            where: a.sales_order_id == ^order_id,
            select: count(a.id)
        ),
      ticket_issues:
        Repo.one!(
          from t in "sales_ticket_issues",
            where: t.sales_order_id == ^order_id,
            select: count(t.id)
        ),
      issued_ticket_issues:
        Repo.one!(
          from t in "sales_ticket_issues",
            where: t.sales_order_id == ^order_id and t.status == "issued",
            select: count(t.id)
        )
    }
  end

  def order_transition_count(order_id, to_state) do
    Repo.one!(
      from st in "sales_state_transitions",
        where:
          st.entity_type == "Order" and st.entity_id == ^to_string(order_id) and
            st.to_state == ^to_state,
        select: count(st.id)
    )
  end

  def inventory_snapshot!(offer_id) do
    {:ok, snapshot} = ReservationLedger.get_availability(offer_id)
    snapshot
  end

  def set_session_expires_at!(session_id, opts \\ []) do
    minutes_ago = Keyword.get(opts, :minutes_ago, 5)

    expires_at =
      DateTime.utc_now() |> DateTime.add(-minutes_ago, :minute) |> DateTime.truncate(:second)

    Repo.update_all(
      from(s in "sales_checkout_sessions", where: s.id == ^session_id),
      set: [expires_at: expires_at, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    reload_session!(session_id)
  end

  def update_inventory_quantity!(offer_id, available_quantity) do
    Redix.command!(FastCheck.Redix, [
      "HSET",
      "sales:offer:#{offer_id}:inventory",
      "available_quantity",
      Integer.to_string(available_quantity)
    ])
  end

  def insert_mobile_event!(attrs \\ %{}) do
    api_key = Map.get(attrs, :tickera_api_key, "tickera-api-key")
    mobile_secret = Map.get(attrs, :mobile_secret, "scanner-secret")
    {:ok, encrypted_api_key} = Crypto.encrypt(api_key)
    {:ok, encrypted_mobile_secret} = Crypto.encrypt(mobile_secret)

    defaults = %{
      name: "VS-22 Mobile Event #{System.unique_integer([:positive])}",
      site_url: "https://example.com",
      tickera_site_url: "https://example.com",
      tickera_api_key_encrypted: encrypted_api_key,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      mobile_access_secret_encrypted: encrypted_mobile_secret,
      scanner_login_code: unique_scanner_code(),
      status: "active",
      entrance_name: "Main Gate"
    }

    attrs =
      defaults
      |> Map.merge(attrs)
      |> Map.delete(:tickera_api_key)
      |> Map.delete(:mobile_secret)

    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert!()
  end

  def e2e_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp read_one!(resource, id) do
    resource
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp actor_for("admin", event_id), do: SalesCheckoutFixtures.admin_actor([event_id])
  defp actor_for("internal_pilot", event_id), do: SalesCheckoutFixtures.admin_actor([event_id])
  defp actor_for("test", event_id), do: SalesCheckoutFixtures.system_actor([event_id])
  defp actor_for(_, event_id), do: SalesCheckoutFixtures.customer_session_actor([event_id])

  defp unique_scanner_code do
    System.unique_integer([:positive])
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end
end
