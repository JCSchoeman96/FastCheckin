defmodule FastCheckWeb.Sales.WhatsAppOfferLive do
  @moduledoc """
  Admin management surface for per-event WhatsApp-compatible ticket offers.

  Thin LiveView adapter over `FastCheck.Sales.OfferManagement`; does not own offer,
  inventory, or checkout domain rules.
  """

  use FastCheckWeb, :live_view

  alias FastCheck.Sales.MoneyInput
  alias FastCheck.Sales.OfferManagement

  @impl true
  def mount(%{"event_id" => event_id_param}, session, socket) do
    with {:ok, user} <- dashboard_user_from_session(session),
         {:ok, event_id} <- OfferManagement.parse_event_id(event_id_param),
         {:ok, %{event: event, archived?: archived?}} <-
           OfferManagement.fetch_event_context(event_id) do
      actor = OfferManagement.admin_actor_from_user(user, event_id)

      case OfferManagement.list_offers(actor, event_id) do
        {:ok, offers} ->
          {:ok,
           socket
           |> assign(:page_title, "WhatsApp ticket offers")
           |> assign(:event, event)
           |> assign(:event_id, event_id)
           |> assign(:archived?, archived?)
           |> assign(:dashboard_user, user)
           |> assign(:actor, actor)
           |> assign(:offers, offers)
           |> assign(:edit_forms, edit_forms_for(offers))
           |> assign(:create_form, to_form(default_create_params(), as: :offer_create))}

        {:error, :not_found} ->
          {:ok,
           socket
           |> put_flash(:error, "Event not found.")
           |> push_navigate(to: ~p"/dashboard")}

        {:error, reason} ->
          {:ok,
           socket
           |> put_flash(:error, OfferManagement.safe_error_message(reason))
           |> push_navigate(to: ~p"/dashboard")}
      end
    else
      {:error, :unauthenticated} ->
        {:ok,
         socket
         |> put_flash(:error, "Sign in to manage WhatsApp ticket offers.")
         |> push_navigate(to: ~p"/login")}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Event not found.")
         |> push_navigate(to: ~p"/dashboard")}

      {:error, :invalid_event_id} ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid event.")
         |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("create_offer", %{"offer_create" => params}, socket) do
    if socket.assigns.archived? do
      {:noreply, put_flash(socket, :error, OfferManagement.safe_error_message(:event_archived))}
    else
      case OfferManagement.create_offer(socket.assigns.actor, socket.assigns.event_id, params) do
        {:ok, _offer} ->
          {:noreply,
           socket
           |> refresh_offers()
           |> assign(:create_form, to_form(default_create_params(), as: :offer_create))
           |> put_flash(:info, "WhatsApp ticket offer created.")}

        {:error, :inventory_initialization_failed} ->
          {:noreply,
           socket
           |> refresh_offers()
           |> put_flash(
             :error,
             OfferManagement.safe_error_message(:inventory_initialization_failed)
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, OfferManagement.safe_error_message(reason))}
      end
    end
  end

  def handle_event("update_offer", %{"offer_id" => offer_id, "offer" => params}, socket) do
    if socket.assigns.archived? do
      {:noreply, put_flash(socket, :error, OfferManagement.safe_error_message(:event_archived))}
    else
      with {:ok, id} <- OfferManagement.parse_event_id(offer_id) do
        case OfferManagement.update_offer(
               socket.assigns.actor,
               socket.assigns.event_id,
               id,
               params
             ) do
          {:ok, _offer} ->
            {:noreply,
             socket
             |> refresh_offers()
             |> put_flash(:info, "Ticket offer updated.")}

          {:error, :stale_offer} ->
            {:noreply,
             socket
             |> refresh_offers()
             |> put_flash(
               :error,
               OfferManagement.safe_error_message(:stale_offer)
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, OfferManagement.safe_error_message(reason))}
        end
      end
    end
  end

  def handle_event("enable_offer", %{"offer_id" => offer_id}, socket) do
    toggle_offer(socket, offer_id, :enable_offer, "Ticket offer enabled.")
  end

  def handle_event("disable_offer", %{"offer_id" => offer_id}, socket) do
    toggle_offer(socket, offer_id, :disable_offer, "Ticket offer disabled.")
  end

  def handle_event("retry_inventory", %{"offer_id" => offer_id}, socket) do
    if socket.assigns.archived? do
      {:noreply, put_flash(socket, :error, OfferManagement.safe_error_message(:event_archived))}
    else
      with {:ok, id} <- OfferManagement.parse_event_id(offer_id) do
        case OfferManagement.retry_inventory_initialization(
               socket.assigns.actor,
               socket.assigns.event_id,
               id
             ) do
          {:ok, _offer} ->
            {:noreply,
             socket
             |> refresh_offers()
             |> put_flash(:info, "Live inventory initialized for this offer.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, OfferManagement.safe_error_message(reason))}
        end
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} breadcrumb={"WhatsApp tickets — #{@event.name}"}>
      <div class="mx-auto max-w-4xl space-y-6 p-4">
        <.card variant="outline" color="natural" rounded="large" padding="large">
          <.card_content class="space-y-3">
            <h1 class="text-xl font-semibold text-fc-text-primary">Manage WhatsApp tickets</h1>
            <p class="text-sm text-fc-text-secondary">
              Configure WhatsApp-compatible ticket offers for {@event.name}. Event-level WhatsApp Sales remains independent from individual offer enablement.
            </p>
            <p class="text-sm text-fc-text-primary">
              Event WhatsApp Sales gate:
              <span class={gate_status_class(@event.whatsapp_sales_enabled)}>
                {if @event.whatsapp_sales_enabled, do: "Enabled", else: "Disabled"}
              </span>
            </p>
            <p :if={@archived?} class="text-sm text-warning-dark">
              This event is archived. Offer management is read-only.
            </p>
          </.card_content>
        </.card>

        <div class="space-y-4">
          <h2 class="text-lg font-semibold text-fc-text-primary">Existing offers</h2>

          <p :if={@offers == []} class="text-sm text-fc-text-secondary">
            No WhatsApp-compatible offers yet.
          </p>

          <.card
            :for={offer <- @offers}
            id={"whatsapp-offer-#{offer.id}"}
            variant="outline"
            color="natural"
            rounded="large"
            padding="large"
          >
            <.card_content class="space-y-4">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <div>
                  <h3 class="text-base font-semibold text-fc-text-primary">{offer.name}</h3>
                  <p class="text-sm text-fc-text-secondary">
                    Channel: {offer.sales_channel} · Status: {if offer.sales_enabled,
                      do: "Enabled",
                      else: "Disabled"}
                  </p>
                </div>
                <div :if={!@archived?} class="flex flex-wrap gap-2">
                  <.button
                    :if={!offer.sales_enabled}
                    id={"enable-offer-#{offer.id}"}
                    type="button"
                    variant="bordered"
                    color="success"
                    size="small"
                    phx-click="enable_offer"
                    phx-value-offer_id={offer.id}
                  >
                    Enable
                  </.button>
                  <.button
                    :if={offer.sales_enabled}
                    id={"disable-offer-#{offer.id}"}
                    type="button"
                    variant="bordered"
                    color="warning"
                    size="small"
                    phx-click="disable_offer"
                    phx-value-offer_id={offer.id}
                  >
                    Disable
                  </.button>
                  <.button
                    :if={!offer.sales_enabled}
                    id={"retry-inventory-#{offer.id}"}
                    type="button"
                    variant="ghost"
                    color="natural"
                    size="small"
                    phx-click="retry_inventory"
                    phx-value-offer_id={offer.id}
                  >
                    Retry inventory setup
                  </.button>
                </div>
              </div>

              <dl class="grid gap-2 text-sm text-fc-text-secondary sm:grid-cols-2">
                <div>
                  <dt class="font-medium text-fc-text-primary">Current selling price</dt>
                  <dd>R {format_price(offer.price_cents)}</dd>
                </div>
                <div>
                  <dt class="font-medium text-fc-text-primary">Regular/reference price</dt>
                  <dd>
                    {if offer.regular_price_cents,
                      do: "R #{format_price(offer.regular_price_cents)}",
                      else: "—"}
                  </dd>
                </div>
                <div>
                  <dt class="font-medium text-fc-text-primary">Max per order</dt>
                  <dd>{offer.max_per_order}</dd>
                </div>
                <div>
                  <dt class="font-medium text-fc-text-primary">Configured quantity</dt>
                  <dd>{offer.configured_quantity_available}</dd>
                </div>
              </dl>

              <.form
                :if={!@archived?}
                for={@edit_forms[offer.id]}
                id={"offer-form-#{offer.id}"}
                phx-submit="update_offer"
                class="space-y-3 border-t border-fc-border-default pt-4"
              >
                <input type="hidden" name="offer_id" value={offer.id} />
                <input type="hidden" name="offer[lock_version]" value={offer.lock_version} />
                <.input field={@edit_forms[offer.id][:name]} type="text" label="Ticket name" required />
                <.input
                  field={@edit_forms[offer.id][:price]}
                  type="text"
                  label="Current WhatsApp selling price (ZAR)"
                  required
                />
                <.input
                  field={@edit_forms[offer.id][:regular_price]}
                  type="text"
                  label="Optional regular/reference price (ZAR)"
                />
                <.input
                  field={@edit_forms[offer.id][:max_per_order]}
                  type="number"
                  label="Max per order (1-9)"
                  min="1"
                  max="9"
                  required
                />
                <.button type="submit" variant="solid" color="primary" size="small">
                  Update offer
                </.button>
              </.form>
            </.card_content>
          </.card>
        </div>

        <.card :if={!@archived?} variant="outline" color="natural" rounded="large" padding="large">
          <.card_content class="space-y-4">
            <h2 class="text-lg font-semibold text-fc-text-primary">Create ticket offer</h2>
            <.form
              for={@create_form}
              id="whatsapp-offer-create-form"
              phx-submit="create_offer"
              class="space-y-3"
            >
              <.input field={@create_form[:name]} type="text" label="Ticket name" required />
              <.input
                field={@create_form[:price]}
                type="text"
                label="Current WhatsApp selling price (ZAR)"
                required
              />
              <.input
                field={@create_form[:regular_price]}
                type="text"
                label="Optional regular/reference price (ZAR)"
              />
              <.input
                field={@create_form[:initial_quantity]}
                type="number"
                label="Initial inventory quantity"
                min="1"
                required
              />
              <.input
                field={@create_form[:max_per_order]}
                type="number"
                label="Max per order (1-9)"
                min="1"
                max="9"
                required
              />
              <.input
                field={@create_form[:sales_enabled]}
                type="checkbox"
                label="Enable sales after inventory setup"
              />
              <.button type="submit" variant="solid" color="primary">Create offer</.button>
            </.form>
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp toggle_offer(socket, offer_id, action, success_message) do
    if socket.assigns.archived? do
      {:noreply, put_flash(socket, :error, OfferManagement.safe_error_message(:event_archived))}
    else
      with {:ok, id} <- OfferManagement.parse_event_id(offer_id),
           {:ok, _offer} <-
             apply(OfferManagement, action, [socket.assigns.actor, socket.assigns.event_id, id]) do
        {:noreply,
         socket
         |> refresh_offers()
         |> put_flash(:info, success_message)}
      else
        {:error, :stale_offer} ->
          {:noreply,
           socket
           |> refresh_offers()
           |> put_flash(:error, OfferManagement.safe_error_message(:stale_offer))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, OfferManagement.safe_error_message(reason))}
      end
    end
  end

  defp refresh_offers(socket) do
    case OfferManagement.list_offers(socket.assigns.actor, socket.assigns.event_id) do
      {:ok, offers} ->
        socket
        |> assign(:offers, offers)
        |> assign(:edit_forms, edit_forms_for(offers))

      {:error, _} ->
        socket
    end
  end

  defp edit_forms_for(offers) do
    Map.new(offers, fn offer ->
      {offer.id, to_form(offer_edit_params(offer), as: :offer)}
    end)
  end

  defp dashboard_user_from_session(session) do
    case session["dashboard_username"] || session[:dashboard_username] do
      username when is_binary(username) and username != "" ->
        {:ok, %{id: username, username: username}}

      _ ->
        {:error, :unauthenticated}
    end
  end

  defp default_create_params do
    %{
      "name" => "",
      "price" => "",
      "regular_price" => "",
      "initial_quantity" => "1",
      "max_per_order" => "1",
      "sales_enabled" => "false"
    }
  end

  defp offer_edit_params(offer) do
    %{
      "name" => offer.name,
      "price" => MoneyInput.format_cents_as_zar(offer.price_cents),
      "regular_price" =>
        if(offer.regular_price_cents,
          do: MoneyInput.format_cents_as_zar(offer.regular_price_cents),
          else: ""
        ),
      "max_per_order" => to_string(offer.max_per_order),
      "lock_version" => to_string(offer.lock_version)
    }
  end

  defp format_price(cents) when is_integer(cents), do: MoneyInput.format_cents_as_zar(cents)
  defp format_price(_), do: "—"

  defp gate_status_class(true), do: "text-success-dark"
  defp gate_status_class(_), do: "text-fc-text-muted"
end
