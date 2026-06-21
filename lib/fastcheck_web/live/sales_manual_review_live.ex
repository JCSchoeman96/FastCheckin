defmodule FastCheckWeb.SalesManualReviewLive do
  @moduledoc """
  Bounded dashboard operations for Sales manual-review records.
  """

  use FastCheckWeb, :live_view

  alias FastCheck.Sales.ManualReview

  @impl true
  def mount(_params, session, socket) do
    filters = %{}

    {:ok,
     socket
     |> assign(:page_title, "Manual review operations")
     |> assign(:actor, actor_from_session(session))
     |> assign(:filters, filters)
     |> assign(:form, to_form(filters, as: :filters))
     |> assign(:action_form, to_form(%{"note" => ""}, as: :review_action))
     |> assign(:selected_subject, nil)
     |> assign(:selected_context, nil)
     |> assign(:action_error, nil)
     |> load_queue(filters)}
  end

  @impl true
  def handle_event("apply_filters", %{"filters" => params}, socket) do
    filters = Map.take(params, ~w(event_id))

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:form, to_form(filters, as: :filters))
     |> assign(:selected_subject, nil)
     |> assign(:selected_context, nil)
     |> assign(:action_error, nil)
     |> load_queue(filters)}
  end

  def handle_event(
        "select_subject",
        %{"subject-type" => subject_type, "subject-id" => subject_id},
        socket
      ) do
    case ManualReview.get_context(subject_type, subject_id) do
      {:ok, context} ->
        {:noreply,
         socket
         |> assign(:selected_subject, %{subject_type: subject_type, subject_id: subject_id})
         |> assign(:selected_context, context)
         |> assign(:action_form, to_form(%{"note" => ""}, as: :review_action))
         |> assign(:action_error, nil)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:selected_subject, nil)
         |> assign(:selected_context, nil)
         |> assign(:action_error, "Review item not found")}
    end
  end

  def handle_event("assign_to_self", subject, socket) do
    run_subject_action(socket, subject, fn subject_type, subject_id, actor ->
      ManualReview.assign(subject_type, subject_id, actor, %{"reason_code" => "operator_assigned"})
    end)
  end

  def handle_event("unassign", subject, socket) do
    run_subject_action(socket, subject, fn subject_type, subject_id, actor ->
      ManualReview.unassign(subject_type, subject_id, actor, %{
        "reason_code" => "operator_unassigned"
      })
    end)
  end

  def handle_event("retry_payment", %{"payment-attempt-id" => attempt_id}, socket) do
    run_action(socket, fn ->
      ManualReview.retry_payment_verification(attempt_id, socket.assigns.actor, %{
        "reason_code" => "retry_payment_verification"
      })
    end)
  end

  def handle_event("retry_issuance", %{"order-id" => order_id}, socket) do
    run_action(socket, fn ->
      ManualReview.retry_ticket_issuance(order_id, socket.assigns.actor, %{
        "reason_code" => "retry_ticket_issuance"
      })
    end)
  end

  def handle_event("hold", %{"order-id" => order_id}, socket) do
    run_action(socket, fn ->
      ManualReview.hold_for_investigation(order_id, socket.assigns.actor, %{
        "reason_code" => "hold_for_investigation"
      })
    end)
  end

  def handle_event("review_action", %{"action" => action, "review_action" => params}, socket) do
    note = Map.get(params, "note", "")

    case action do
      "add_note" ->
        run_subject_action(socket, socket.assigns.selected_subject, fn subject_type,
                                                                       subject_id,
                                                                       actor ->
          ManualReview.add_note(subject_type, subject_id, actor, %{
            "reason_code" => "operator_note",
            "note" => note
          })
        end)

      "close_no_fulfillment" ->
        run_order_action(socket, fn order_id, actor ->
          ManualReview.close_no_fulfillment(order_id, actor, %{
            "reason_code" => "close_no_fulfillment",
            "note" => note
          })
        end)

      "return_to_fulfillment_queue" ->
        run_order_action(socket, fn order_id, actor ->
          ManualReview.return_to_fulfillment_queue(order_id, actor, %{
            "reason_code" => "return_to_fulfillment_queue",
            "note" => note
          })
        end)

      _ ->
        {:noreply, assign(socket, :action_error, "Unsupported review action")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} breadcrumb="Manual review operations">
      <div class="mx-auto max-w-7xl space-y-6 p-4">
        <header class="space-y-2">
          <h1 class="text-2xl font-semibold text-fc-text-primary">Manual review operations</h1>
          <p class="text-sm text-fc-text-secondary">
            Safe review, assignment, notes, holds, and retry queueing for Sales exceptions.
          </p>
        </header>

        <.form
          for={@form}
          id="manual-review-filters"
          phx-submit="apply_filters"
          class="grid gap-3 rounded-lg border border-fc-border bg-white/70 p-4 md:grid-cols-3"
        >
          <.input field={@form[:event_id]} type="number" label="Event ID" />
          <div class="flex items-end">
            <.button type="submit" variant="solid" color="primary">Apply filters</.button>
          </div>
        </.form>

        <p
          :if={@action_error}
          class="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800"
        >
          {@action_error}
        </p>

        <section class="grid gap-6 xl:grid-cols-[1.25fr_1fr]">
          <.card variant="outline" color="natural" rounded="large" padding="large">
            <.card_content>
              <div class="flex items-center justify-between gap-4">
                <h2 class="text-lg font-semibold text-fc-text-primary">Review queue</h2>
                <p class="text-sm text-fc-text-muted">{length(@queue.entries)} shown</p>
              </div>

              <div class="mt-4 overflow-x-auto">
                <table class="min-w-full text-left text-sm">
                  <thead class="text-xs uppercase text-fc-text-muted">
                    <tr>
                      <th class="py-2 pr-4">Subject</th>
                      <th class="py-2 pr-4">Reference</th>
                      <th class="py-2 pr-4">Status</th>
                      <th class="py-2 pr-4">Reason</th>
                      <th class="py-2 pr-4">Buyer</th>
                      <th class="py-2 pr-4">Action</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :if={Enum.empty?(@queue.entries)}>
                      <td colspan="6" class="py-6 text-fc-text-secondary">No review items.</td>
                    </tr>
                    <tr :for={entry <- @queue.entries} class="border-t border-fc-border">
                      <td class="py-3 pr-4">{format_subject_type(entry.subject_type)}</td>
                      <td class="py-3 pr-4 font-medium text-fc-text-primary">
                        {entry.order_public_reference}
                      </td>
                      <td class="py-3 pr-4">{format_status(entry.current_status)}</td>
                      <td class="py-3 pr-4">{entry.reason_code}</td>
                      <td class="py-3 pr-4">
                        <div class="text-xs text-fc-text-muted">{entry.buyer_email_masked}</div>
                        <div class="text-xs text-fc-text-muted">{entry.buyer_phone_masked}</div>
                      </td>
                      <td class="py-3 pr-4">
                        <.button
                          type="button"
                          variant="ghost"
                          color="primary"
                          phx-click="select_subject"
                          phx-value-subject-type={entry.subject_type}
                          phx-value-subject-id={entry.subject_id}
                        >
                          Open review
                        </.button>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </.card_content>
          </.card>

          <.card variant="outline" color="natural" rounded="large" padding="large">
            <.card_content>
              <h2 class="text-lg font-semibold text-fc-text-primary">Review detail</h2>
              <p :if={is_nil(@selected_context)} class="mt-4 text-sm text-fc-text-secondary">
                Select a queue item.
              </p>
              <div :if={@selected_context} class="mt-4 space-y-4 text-sm">
                <div>
                  <p class="text-base font-semibold text-fc-text-primary">
                    {@selected_context.order_public_reference}
                  </p>
                  <p class="text-fc-text-secondary">
                    {format_subject_type(@selected_context.subject_type)} · {format_status(
                      @selected_context.current_status
                    )}
                  </p>
                  <p class="text-xs text-fc-text-muted">{@selected_context.buyer_email_masked}</p>
                  <p class="text-xs text-fc-text-muted">{@selected_context.buyer_phone_masked}</p>
                </div>

                <div
                  :if={@selected_context.payment_summary}
                  class="rounded-md border border-fc-border p-3"
                >
                  <h3 class="text-sm font-semibold text-fc-text-primary">Payment summary</h3>
                  <p class="text-xs text-fc-text-muted">
                    {format_status(@selected_context.payment_summary.status)} · {@selected_context.payment_summary.amount_cents}
                    {@selected_context.payment_summary.currency}
                  </p>
                  <p class="text-xs text-fc-text-muted">
                    Provider ref {@selected_context.payment_summary.provider_reference_masked}
                  </p>
                </div>

                <div
                  :if={
                    @selected_context.ticket_issue_summary ||
                      (@selected_context.ticket_issue_summaries || []) != []
                  }
                  class="rounded-md border border-fc-border p-3"
                >
                  <h3 class="text-sm font-semibold text-fc-text-primary">Ticket summary</h3>
                  <div
                    :if={@selected_context.ticket_issue_summary}
                    class="text-xs text-fc-text-muted"
                  >
                    {format_status(@selected_context.ticket_issue_summary.status)} · scanner {@selected_context.ticket_issue_summary.scanner_status} ·
                    code {@selected_context.ticket_issue_summary.ticket_code_suffix}
                  </div>
                  <div
                    :for={issue <- List.wrap(@selected_context.ticket_issue_summaries)}
                    class="text-xs text-fc-text-muted"
                  >
                    {format_status(issue.status)} · scanner {issue.scanner_status} · code {issue.ticket_code_suffix}
                  </div>
                </div>

                <div class="flex flex-wrap gap-2">
                  <.button
                    type="button"
                    variant="outline"
                    color="primary"
                    phx-click="assign_to_self"
                    phx-value-subject-type={@selected_context.subject_type}
                    phx-value-subject-id={@selected_context.subject_id}
                  >
                    Assign
                  </.button>
                  <.button
                    type="button"
                    variant="outline"
                    color="natural"
                    phx-click="unassign"
                    phx-value-subject-type={@selected_context.subject_type}
                    phx-value-subject-id={@selected_context.subject_id}
                  >
                    Unassign
                  </.button>
                  <.button
                    :if={@selected_context.can_retry_payment?}
                    type="button"
                    variant="outline"
                    color="primary"
                    phx-click="retry_payment"
                    phx-value-payment-attempt-id={@selected_context.payment_attempt_id}
                  >
                    Queue payment retry
                  </.button>
                  <.button
                    type="button"
                    variant="outline"
                    color="primary"
                    phx-click="retry_issuance"
                    phx-value-order-id={@selected_context.sales_order_id}
                  >
                    Queue issuance retry
                  </.button>
                  <.button
                    type="button"
                    variant="outline"
                    color="warning"
                    phx-click="hold"
                    phx-value-order-id={@selected_context.sales_order_id}
                  >
                    Hold
                  </.button>
                </div>

                <.form
                  for={@action_form}
                  id="manual-review-actions"
                  phx-submit="review_action"
                  class="space-y-3 rounded-md border border-fc-border p-3"
                >
                  <.input
                    field={@action_form[:note]}
                    type="textarea"
                    label="Operator note"
                    placeholder="Add context for notes, close, or return actions"
                  />
                  <div class="flex flex-wrap gap-2">
                    <.button
                      type="submit"
                      name="action"
                      value="add_note"
                      variant="outline"
                      color="primary"
                    >
                      Add note
                    </.button>
                    <.button
                      :if={@selected_context.can_close_no_fulfillment?}
                      type="submit"
                      name="action"
                      value="close_no_fulfillment"
                      variant="outline"
                      color="danger"
                      data-confirm="Close this order without fulfillment? This action is audited and cannot be undone from here."
                    >
                      Close no fulfillment
                    </.button>
                    <.button
                      :if={@selected_context.can_return_to_fulfillment?}
                      type="submit"
                      name="action"
                      value="return_to_fulfillment_queue"
                      variant="outline"
                      color="primary"
                      data-confirm="Return this order to the fulfillment queue only when payment and issuance preconditions are safe."
                    >
                      Return to fulfillment queue
                    </.button>
                  </div>
                </.form>

                <div>
                  <h3 class="text-sm font-semibold text-fc-text-primary">Timeline</h3>
                  <div class="mt-2 space-y-2">
                    <p :if={Enum.empty?(@selected_context.timeline)} class="text-fc-text-secondary">
                      No actions yet.
                    </p>
                    <div
                      :for={item <- @selected_context.timeline}
                      class="rounded-md border border-fc-border p-2"
                    >
                      <p class="font-medium text-fc-text-primary">{item.action}</p>
                      <p class="text-xs text-fc-text-muted">
                        {format_status(item.previous_status)} -> {format_status(item.new_status)}
                      </p>
                    </div>
                  </div>
                </div>
              </div>
            </.card_content>
          </.card>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp load_queue(socket, filters), do: assign(socket, :queue, ManualReview.list_queue(filters))

  defp run_subject_action(socket, nil, _fun) do
    {:noreply, assign(socket, :action_error, "Select a review item first")}
  end

  defp run_subject_action(socket, subject, fun) do
    subject_type = Map.get(subject, :subject_type) || Map.get(subject, "subject-type")
    subject_id = Map.get(subject, :subject_id) || Map.get(subject, "subject-id")

    run_action(socket, fn -> fun.(subject_type, subject_id, socket.assigns.actor) end)
  end

  defp run_order_action(socket, fun) do
    case socket.assigns.selected_context do
      %{sales_order_id: order_id} when not is_nil(order_id) ->
        run_action(socket, fn -> fun.(order_id, socket.assigns.actor) end)

      _ ->
        {:noreply, assign(socket, :action_error, "Select a review item first")}
    end
  end

  defp run_action(socket, fun) do
    case fun.() do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(:action_error, nil)
         |> assign(:action_form, to_form(%{"note" => ""}, as: :review_action))
         |> load_queue(socket.assigns.filters)
         |> reload_selected_context()}

      {:error, reason} ->
        {:noreply, assign(socket, :action_error, format_error(reason))}
    end
  end

  defp reload_selected_context(%{assigns: %{selected_subject: nil}} = socket), do: socket

  defp reload_selected_context(socket) do
    %{subject_type: subject_type, subject_id: subject_id} = socket.assigns.selected_subject

    case ManualReview.get_context(subject_type, subject_id) do
      {:ok, context} ->
        assign(socket, :selected_context, context)

      {:error, _} ->
        socket
        |> assign(:selected_subject, nil)
        |> assign(:selected_context, nil)
    end
  end

  defp actor_from_session(session) do
    username = session["dashboard_username"] || "dashboard"
    %{id: username, username: username}
  end

  defp format_error(reason), do: reason |> to_string() |> String.replace("_", " ")

  defp format_status(nil), do: "None"

  defp format_status(status),
    do: status |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp format_subject_type("order"), do: "Order"
  defp format_subject_type("payment_attempt"), do: "Payment attempt"
  defp format_subject_type("ticket_issue"), do: "Ticket issue"
  defp format_subject_type(subject_type), do: subject_type |> to_string() |> String.capitalize()
end
