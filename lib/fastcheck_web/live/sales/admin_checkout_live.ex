defmodule FastCheckWeb.Sales.AdminCheckoutLive do
  @moduledoc """
  Admin-assisted Sales checkout entrypoint for dashboard operators.

  Thin LiveView adapter over `FastCheck.Sales.SecondaryEntrypoints`; does not
  own checkout, inventory, or payment logic.
  """

  use FastCheckWeb, :live_view

  alias FastCheck.Sales.SecondaryEntrypoints

  @impl true
  def mount(%{"event_id" => event_id_param}, session, socket) do
    with {:ok, user} <- dashboard_user_from_session(session),
         {:ok, event_id} <- SecondaryEntrypoints.parse_event_id(event_id_param),
         {:ok, event} <- SecondaryEntrypoints.safe_fetch_event(event_id) do
      actor = SecondaryEntrypoints.admin_actor_from_user(user, event_id)

      case SecondaryEntrypoints.list_offers_for_channel(actor, event_id, "admin") do
        {:ok, offers} ->
          {:ok,
           socket
           |> assign(:page_title, "Admin checkout")
           |> assign(:event, event)
           |> assign(:event_id, event_id)
           |> assign(:offers, offers)
           |> assign(:dashboard_user, user)
           |> assign(:idempotency_key, SecondaryEntrypoints.generate_idempotency_key())
           |> assign(:form, to_form(default_form_params(offers), as: :checkout))}

        {:error, _reason} ->
          {:ok,
           socket
           |> put_flash(:error, "Unable to load ticket offers.")
           |> push_navigate(to: ~p"/dashboard")}
      end
    else
      {:error, :unauthenticated} ->
        {:ok,
         socket
         |> put_flash(:error, "Sign in to start admin checkout.")
         |> push_navigate(to: ~p"/login")}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Event not found.")
         |> push_navigate(to: ~p"/dashboard")}

      {:error, :invalid} ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid event.")
         |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("start_checkout", %{"checkout" => params}, socket) do
    user = socket.assigns.dashboard_user
    event_id = socket.assigns.event_id
    idempotency_key = socket.assigns.idempotency_key

    case SecondaryEntrypoints.start_admin_checkout(user, event_id, params, idempotency_key) do
      {:ok, %{public_reference: ref}} ->
        {:noreply,
         socket
         |> assign(:idempotency_key, SecondaryEntrypoints.generate_idempotency_key())
         |> put_flash(:info, "Checkout started. Reference: #{ref}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, SecondaryEntrypoints.safe_error_message(reason))}
    end
  end

  def handle_event("reset_checkout", _params, socket) do
    {:noreply, assign(socket, :idempotency_key, SecondaryEntrypoints.generate_idempotency_key())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} breadcrumb={"Admin checkout — #{@event.name}"}>
      <div class="mx-auto max-w-2xl space-y-6 p-4">
        <.card variant="outline" color="natural" rounded="large" padding="large">
          <.card_content class="space-y-4">
            <h1 class="text-xl font-semibold text-fc-text-primary">Admin-assisted checkout</h1>
            <p class="text-sm text-fc-text-secondary">
              Start a Sales checkout for {@event.name}. Payment and ticket delivery are handled by later Sales flows.
            </p>

            <.form for={@form} id="admin-checkout-form" phx-submit="start_checkout" class="space-y-4">
              <.input
                field={@form[:ticket_offer_id]}
                type="select"
                label="Ticket offer"
                options={offer_options(@offers)}
                prompt="Select an offer"
                required
              />
              <.input field={@form[:quantity]} type="number" label="Quantity" min="1" required />
              <.input field={@form[:buyer_name]} type="text" label="Buyer name" />
              <.input field={@form[:buyer_phone]} type="text" label="Buyer phone" />
              <.input field={@form[:buyer_email]} type="email" label="Buyer email" />
              <div class="flex gap-3">
                <.button type="submit" variant="solid" color="primary">Start checkout</.button>
                <.button type="button" variant="ghost" color="natural" phx-click="reset_checkout">
                  Start over
                </.button>
              </div>
            </.form>
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp dashboard_user_from_session(session) do
    case session["dashboard_username"] || session[:dashboard_username] do
      username when is_binary(username) and username != "" ->
        {:ok, %{id: username, username: username}}

      _ ->
        {:error, :unauthenticated}
    end
  end

  defp default_form_params(offers) do
    default_offer_id =
      case offers do
        [%{id: id} | _] -> to_string(id)
        _ -> ""
      end

    %{
      "ticket_offer_id" => default_offer_id,
      "quantity" => "1",
      "buyer_name" => "",
      "buyer_phone" => "",
      "buyer_email" => ""
    }
  end

  defp offer_options(offers) do
    Enum.map(offers, fn offer ->
      label = "#{offer.name} — #{format_price(offer.price_cents, offer.currency)}"
      {label, to_string(offer.id)}
    end)
  end

  defp format_price(cents, currency) when is_integer(cents) do
    major = div(cents, 100)
    minor = rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{currency} #{major}.#{minor}"
  end

  defp format_price(_, currency), do: currency
end
