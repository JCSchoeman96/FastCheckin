defmodule FastCheck.Messaging.WhatsApp.ConversationStateMachine do
  @moduledoc """
  VS-18 WhatsApp number-only conversation flow up to checkout start.
  """

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Events.Event
  alias FastCheck.Messaging.WhatsApp.FlowResult
  alias FastCheck.Messaging.WhatsApp.InputNormalizer
  alias FastCheck.Messaging.WhatsApp.MenuRenderer
  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Messaging.WhatsApp.PaymentFlow
  alias FastCheck.Messaging.WhatsApp.SessionStore
  alias FastCheck.Repo
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.TicketOffer

  @menu_limit 9
  @event_candidate_limit 50
  @session_ttl_seconds 86_400
  @selected_event_keys [
    "selected_event_id",
    "selected_event_label"
  ]
  @selected_offer_keys [
    "selected_offer_id",
    "selected_offer_label",
    "selected_offer_max_per_order",
    "selected_offer_price_cents",
    "selected_offer_currency"
  ]
  @buyer_keys [
    "buyer_name",
    "buyer_email"
  ]
  @order_flow_keys [
    "sales_order_id",
    "payment_attempt_id",
    "order_public_reference"
  ]
  @all_flow_keys [
                   "event_options",
                   "offer_options",
                   "quantity"
                 ] ++
                   @selected_event_keys ++ @selected_offer_keys ++ @buyer_keys ++ @order_flow_keys

  @spec handle_inbound(MessageCommand.t(), Conversation.t()) ::
          {:ok, FlowResult.t()} | {:error, term()}
  def handle_inbound(%MessageCommand{} = command, %Conversation{} = conversation) do
    if duplicate_inbound?(command, conversation) do
      {:ok, duplicate_result(conversation)}
    else
      normalized = InputNormalizer.normalize(command.text_body || "")

      case dispatch(command, conversation, normalized) do
        {:ok, result} -> mark_handled(command, result)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp dispatch(command, conversation, {:ok, :help}) do
    {:ok, result(conversation, MenuRenderer.help(language(conversation)), command)}
  end

  defp dispatch(command, conversation, {:ok, :stop})
       when conversation.state in [
              "new",
              "selecting_language",
              "main_menu",
              "selecting_event",
              "selecting_ticket_type",
              "collecting_quantity",
              "collecting_buyer_name",
              "collecting_email",
              "confirming_order"
            ] do
    with {:ok, conversation} <-
           transition(command, conversation, :cancel_conversation, %{
             reason: "customer_stop_command",
             state_data: state_data(conversation)
           }) do
      {:ok, result(conversation, MenuRenderer.cancelled(language(conversation)), command)}
    end
  end

  defp dispatch(command, conversation, {:ok, :stop}) do
    {:ok, result(conversation, MenuRenderer.payment_pending(language(conversation)), command)}
  end

  defp dispatch(command, conversation, {:ok, :restart}) do
    with {:ok, conversation} <-
           transition(command, conversation, :return_to_main_menu, %{state_data: %{}}) do
      {:ok, result(conversation, MenuRenderer.main_menu(language(conversation)), command)}
    end
  end

  defp dispatch(command, conversation, _normalized) when conversation.state == "new" do
    with {:ok, conversation} <-
           transition(command, conversation, :start_language_selection, %{state_data: %{}}) do
      {:ok, result(conversation, MenuRenderer.language_prompt(), command)}
    end
  end

  defp dispatch(command, conversation, {:ok, {:number, 1}})
       when conversation.state == "selecting_language" do
    attrs = %{preferred_language: "af", state_data: state_data(conversation)}

    with {:ok, conversation} <- transition(command, conversation, :select_language, attrs) do
      {:ok, result(conversation, MenuRenderer.main_menu("af"), command)}
    end
  end

  defp dispatch(command, conversation, {:ok, {:number, 2}})
       when conversation.state == "selecting_language" do
    attrs = %{preferred_language: "en", state_data: state_data(conversation)}

    with {:ok, conversation} <- transition(command, conversation, :select_language, attrs) do
      {:ok, result(conversation, MenuRenderer.main_menu("en"), command)}
    end
  end

  defp dispatch(command, conversation, _normalized)
       when conversation.state == "selecting_language" do
    {:ok,
     result(
       conversation,
       MenuRenderer.invalid_input(language(conversation), MenuRenderer.language_prompt()),
       command
     )}
  end

  defp dispatch(command, conversation, {:ok, {:number, 1}})
       when conversation.state == "main_menu" do
    case sellable_events() do
      [] ->
        {:ok, result(conversation, MenuRenderer.no_events(language(conversation)), command)}

      events ->
        data = Map.put(state_data(conversation), "event_options", option_ids(events))

        with {:ok, conversation} <-
               transition(command, conversation, :choose_buy_tickets, %{state_data: data}) do
          {:ok,
           result(conversation, MenuRenderer.event_menu(language(conversation), events), command)}
        end
    end
  end

  defp dispatch(command, conversation, {:ok, {:number, 2}})
       when conversation.state == "main_menu" do
    {:ok, result(conversation, MenuRenderer.help(language(conversation)), command)}
  end

  defp dispatch(command, conversation, {:ok, :back}) when conversation.state == "main_menu" do
    {:ok, result(conversation, MenuRenderer.main_menu(language(conversation)), command)}
  end

  defp dispatch(command, conversation, _normalized) when conversation.state == "main_menu" do
    {:ok,
     result(
       conversation,
       MenuRenderer.invalid_input(
         language(conversation),
         MenuRenderer.main_menu(language(conversation))
       ),
       command
     )}
  end

  defp dispatch(command, conversation, {:ok, :back})
       when conversation.state == "selecting_event" do
    with {:ok, conversation} <-
           transition(command, conversation, :return_to_main_menu, %{
             state_data: clear_current_flow(state_data(conversation))
           }) do
      {:ok, result(conversation, MenuRenderer.main_menu(language(conversation)), command)}
    end
  end

  defp dispatch(command, conversation, {:ok, :back})
       when conversation.state == "selecting_ticket_type" do
    return_to_refreshed_event_selection(command, conversation)
  end

  defp dispatch(command, conversation, {:ok, {:number, index}})
       when conversation.state == "selecting_event" do
    data = state_data(conversation)

    with {:ok, event_id} <- option_id(data, "event_options", index),
         offers when offers != [] <- active_offers(event_id),
         event <- event_label(event_id),
         data <-
           data
           |> Map.put("selected_event_id", event_id)
           |> Map.put("selected_event_label", event)
           |> Map.put("offer_options", option_ids(offers)),
         {:ok, conversation} <-
           transition(command, conversation, :select_event, %{state_data: data}) do
      {:ok,
       result(conversation, MenuRenderer.offer_menu(language(conversation), offers), command)}
    else
      _ -> repeat_event_menu(command, conversation)
    end
  end

  defp dispatch(command, conversation, _normalized)
       when conversation.state == "selecting_event" do
    repeat_event_menu(command, conversation)
  end

  defp dispatch(command, conversation, {:ok, {:number, index}})
       when conversation.state == "selecting_ticket_type" do
    data = state_data(conversation)
    event_id = Map.get(data, "selected_event_id")

    with {:ok, offer_id} <- option_id(data, "offer_options", index),
         {:ok, offer} <- active_offer(event_id, offer_id),
         data <-
           data
           |> Map.put("selected_offer_id", offer.id)
           |> Map.put("selected_offer_label", offer.name)
           |> Map.put("selected_offer_max_per_order", offer.max_per_order)
           |> Map.put("selected_offer_price_cents", offer.price_cents)
           |> Map.put("selected_offer_currency", offer.currency),
         {:ok, conversation} <-
           transition(command, conversation, :select_ticket_type, %{state_data: data}) do
      {:ok, result(conversation, MenuRenderer.quantity_prompt(language(conversation)), command)}
    else
      _ -> repeat_offer_menu(command, conversation)
    end
  end

  defp dispatch(command, conversation, _normalized)
       when conversation.state == "selecting_ticket_type" do
    repeat_offer_menu(command, conversation)
  end

  defp dispatch(command, conversation, {:ok, :back})
       when conversation.state == "collecting_quantity" do
    data = state_data(conversation)
    event_id = Map.get(data, "selected_event_id")
    offers = active_offers(event_id)

    if offers == [] do
      return_to_refreshed_event_selection(command, conversation)
    else
      data =
        data
        |> clear_after_offer_selection()
        |> Map.put("offer_options", option_ids(offers))

      with {:ok, conversation} <-
             transition(command, conversation, :return_to_ticket_type_selection, %{
               state_data: data
             }) do
        {:ok,
         result(conversation, MenuRenderer.offer_menu(language(conversation), offers), command)}
      end
    end
  end

  defp dispatch(command, conversation, {:ok, {:number, quantity}})
       when conversation.state == "collecting_quantity" do
    data = state_data(conversation)
    max = Map.get(data, "selected_offer_max_per_order", 1)

    if quantity <= max do
      with {:ok, conversation} <-
             transition(command, conversation, :submit_quantity, %{
               state_data: Map.put(data, "quantity", quantity)
             }) do
        {:ok,
         result(conversation, MenuRenderer.buyer_name_prompt(language(conversation)), command)}
      end
    else
      {:ok,
       result(
         conversation,
         MenuRenderer.invalid_input(
           language(conversation),
           MenuRenderer.quantity_prompt(language(conversation))
         ),
         command
       )}
    end
  end

  defp dispatch(command, conversation, _normalized)
       when conversation.state == "collecting_quantity" do
    {:ok,
     result(
       conversation,
       MenuRenderer.invalid_input(
         language(conversation),
         MenuRenderer.quantity_prompt(language(conversation))
       ),
       command
     )}
  end

  defp dispatch(command, conversation, {:ok, :back})
       when conversation.state == "collecting_buyer_name" do
    with {:ok, conversation} <-
           transition(command, conversation, :return_to_quantity_collection, %{
             state_data: clear_after_quantity(state_data(conversation))
           }) do
      {:ok, result(conversation, MenuRenderer.quantity_prompt(language(conversation)), command)}
    end
  end

  defp dispatch(command, conversation, {:ok, {:text, buyer_name}})
       when conversation.state == "collecting_buyer_name" do
    with {:ok, conversation} <-
           transition(command, conversation, :submit_buyer_name, %{
             state_data: Map.put(state_data(conversation), "buyer_name", buyer_name)
           }) do
      {:ok, result(conversation, MenuRenderer.email_prompt(language(conversation)), command)}
    end
  end

  defp dispatch(command, conversation, _normalized)
       when conversation.state == "collecting_buyer_name" do
    {:ok,
     result(
       conversation,
       MenuRenderer.invalid_input(
         language(conversation),
         MenuRenderer.buyer_name_prompt(language(conversation))
       ),
       command
     )}
  end

  defp dispatch(command, conversation, {:ok, :back})
       when conversation.state == "collecting_email" do
    with {:ok, conversation} <-
           transition(command, conversation, :return_to_buyer_name_collection, %{
             state_data: clear_after_buyer_name(state_data(conversation))
           }) do
      {:ok, result(conversation, MenuRenderer.buyer_name_prompt(language(conversation)), command)}
    end
  end

  defp dispatch(command, conversation, {:ok, {:number, 1}})
       when conversation.state == "collecting_email" do
    with {:ok, conversation} <-
           transition(command, conversation, :skip_optional_email_after_name, %{
             state_data: Map.put(state_data(conversation), "buyer_email", nil)
           }) do
      {:ok, result(conversation, confirm_menu(conversation), command)}
    end
  end

  defp dispatch(command, conversation, {:ok, {:text, email}})
       when conversation.state == "collecting_email" do
    if valid_email?(email) do
      with {:ok, conversation} <-
             transition(command, conversation, :submit_buyer_email, %{
               state_data: Map.put(state_data(conversation), "buyer_email", email)
             }) do
        {:ok, result(conversation, confirm_menu(conversation), command)}
      end
    else
      {:ok,
       result(
         conversation,
         MenuRenderer.invalid_input(
           language(conversation),
           MenuRenderer.email_prompt(language(conversation))
         ),
         command
       )}
    end
  end

  defp dispatch(command, conversation, _normalized)
       when conversation.state == "collecting_email" do
    {:ok,
     result(
       conversation,
       MenuRenderer.invalid_input(
         language(conversation),
         MenuRenderer.email_prompt(language(conversation))
       ),
       command
     )}
  end

  defp dispatch(command, conversation, {:ok, :back})
       when conversation.state == "confirming_order" do
    with {:ok, conversation} <-
           transition(command, conversation, :return_to_email_collection, %{
             state_data: clear_after_email(state_data(conversation))
           }) do
      {:ok, result(conversation, MenuRenderer.email_prompt(language(conversation)), command)}
    end
  end

  defp dispatch(command, conversation, {:ok, {:number, 1}})
       when conversation.state == "confirming_order" do
    PaymentFlow.confirm_checkout_from_conversation(command, conversation)
  end

  defp dispatch(command, conversation, _normalized)
       when conversation.state == "confirming_order" do
    {:ok,
     result(
       conversation,
       MenuRenderer.invalid_input(language(conversation), confirm_menu(conversation)),
       command
     )}
  end

  defp dispatch(command, conversation, _normalized)
       when conversation.state in [
              "awaiting_payment",
              "payment_pending",
              "payment_received",
              "ticket_issued",
              "completed",
              "manual_review",
              "expired",
              "cancelled"
            ] do
    PaymentFlow.respond_to_status_request(command, conversation)
  end

  defp dispatch(command, conversation, _normalized) do
    {:ok, result(conversation, MenuRenderer.main_menu(language(conversation)), command)}
  end

  defp return_to_refreshed_event_selection(command, conversation) do
    events = sellable_events()

    if events == [] do
      with {:ok, conversation} <-
             transition(command, conversation, :return_to_main_menu, %{
               state_data: clear_current_flow(state_data(conversation))
             }) do
        {:ok, result(conversation, MenuRenderer.no_events(language(conversation)), command)}
      end
    else
      data =
        conversation
        |> state_data()
        |> clear_after_event_selection()
        |> Map.put("event_options", option_ids(events))

      with {:ok, conversation} <-
             transition(command, conversation, :return_to_event_selection, %{state_data: data}) do
        {:ok,
         result(conversation, MenuRenderer.event_menu(language(conversation), events), command)}
      end
    end
  end

  defp repeat_event_menu(command, conversation) do
    events = sellable_events()

    {:ok,
     result(
       conversation,
       MenuRenderer.invalid_input(
         language(conversation),
         MenuRenderer.event_menu(language(conversation), events)
       ),
       command
     )}
  end

  defp repeat_offer_menu(command, conversation) do
    data = state_data(conversation)
    offers = active_offers(Map.get(data, "selected_event_id"))

    {:ok,
     result(
       conversation,
       MenuRenderer.invalid_input(
         language(conversation),
         MenuRenderer.offer_menu(language(conversation), offers)
       ),
       command
     )}
  end

  defp confirm_menu(conversation) do
    data = state_data(conversation)

    MenuRenderer.confirm_order(language(conversation), %{
      buyer_name: Map.get(data, "buyer_name"),
      buyer_email: Map.get(data, "buyer_email"),
      event_label: Map.get(data, "selected_event_label"),
      offer_label: Map.get(data, "selected_offer_label"),
      price_cents: Map.get(data, "selected_offer_price_cents"),
      currency: Map.get(data, "selected_offer_currency"),
      quantity: Map.get(data, "quantity")
    })
  end

  defp transition(command, conversation, action, attrs) do
    attrs =
      attrs
      |> Map.put(:last_inbound_message_id, command.provider_message_id)
      |> Map.put(:last_message_at, command.received_at)
      |> Map.put(:expires_at, DateTime.add(command.received_at, session_ttl_seconds(), :second))
      |> Map.put(:correlation_id, command.correlation_id)
      |> Map.put(:idempotency_key, command.provider_message_id)
      |> Map.put(:transition_metadata, %{
        source_channel: "whatsapp",
        message_type: command.message_type
      })

    actor = %{actor_type: :system, actor_id: "whatsapp_conversation_state_machine"}

    conversation
    |> Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update(authorize?: false)
  end

  defp result(conversation, body, command) do
    flow_fields = flow_fields(conversation)
    _ = SessionStore.put_flow_session(command, conversation, flow_fields, session_ttl_seconds())

    %FlowResult{
      conversation: conversation,
      response_body: body,
      session_fields: flow_fields,
      send_reply?: true
    }
  end

  defp duplicate_result(conversation) do
    %FlowResult{
      conversation: conversation,
      response_body: "",
      session_fields: flow_fields(conversation),
      send_reply?: false
    }
  end

  defp duplicate_inbound?(command, conversation) do
    is_binary(command.provider_message_id) and command.provider_message_id != "" and
      state_data(conversation)["last_handled_inbound_message_id"] == command.provider_message_id
  end

  defp mark_handled(_command, %{send_reply?: false} = result), do: {:ok, result}

  defp mark_handled(command, %FlowResult{conversation: conversation} = result) do
    data =
      conversation
      |> state_data()
      |> Map.put("last_handled_inbound_message_id", command.provider_message_id)

    actor = %{actor_type: :system, actor_id: "whatsapp_conversation_state_machine"}

    conversation
    |> Changeset.for_update(:update_inbound_checkpoint, %{state_data: data}, actor: actor)
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, conversation} -> {:ok, %{result | conversation: conversation}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp flow_fields(conversation) do
    data = state_data(conversation)

    %{
      selected_event_id: Map.get(data, "selected_event_id"),
      selected_offer_id: Map.get(data, "selected_offer_id"),
      quantity: Map.get(data, "quantity"),
      sales_order_id: Map.get(data, "sales_order_id"),
      order_public_reference: Map.get(data, "order_public_reference"),
      version: Map.get(data, "version", 0)
    }
  end

  defp sellable_events do
    events =
      from(e in Event,
        where: e.status != "archived",
        order_by: [desc: e.id],
        limit: ^@event_candidate_limit,
        select: %{id: e.id, label: e.name}
      )
      |> Repo.all()

    events
    |> Enum.filter(fn event -> active_offers(event.id) != [] end)
    |> Enum.take(@menu_limit)
  end

  defp active_offers(event_id) when is_integer(event_id) do
    actor = customer_actor(event_id)

    TicketOffer
    |> Query.for_read(
      :list_active_for_event,
      %{event_id: event_id, sales_channel: "whatsapp", as_of: DateTime.utc_now()},
      actor: actor
    )
    |> Ash.read(authorize?: true)
    |> case do
      {:ok, offers} ->
        offers
        |> Enum.map(
          &%{
            id: &1.id,
            label: &1.name,
            name: &1.name,
            max_per_order: &1.max_per_order,
            price_cents: &1.price_cents,
            currency: &1.currency
          }
        )
        |> Enum.take(@menu_limit)

      {:error, _} ->
        []
    end
  end

  defp active_offers(_event_id), do: []

  defp active_offer(event_id, offer_id) do
    event_id
    |> active_offers()
    |> Enum.find(&(&1.id == offer_id))
    |> case do
      nil -> {:error, :offer_not_found}
      offer -> {:ok, offer}
    end
  end

  defp option_ids(rows),
    do:
      rows
      |> Enum.map(& &1.id)
      |> Enum.with_index(1)
      |> Map.new(fn {id, index} -> {to_string(index), id} end)

  defp option_id(data, key, index) do
    case get_in(data, [key, to_string(index)]) do
      id when is_integer(id) -> {:ok, id}
      _ -> {:error, :invalid_option}
    end
  end

  defp event_label(event_id) do
    from(e in Event, where: e.id == ^event_id, select: e.name)
    |> Repo.one()
  end

  defp clear_current_flow(data), do: drop_flow_keys(data, @all_flow_keys)

  defp clear_after_event_selection(data) do
    drop_flow_keys(
      data,
      @selected_event_keys ++
        @selected_offer_keys ++
        @buyer_keys ++
        @order_flow_keys ++
        ["offer_options", "quantity"]
    )
  end

  defp clear_after_offer_selection(data) do
    drop_flow_keys(
      data,
      @selected_offer_keys ++ @buyer_keys ++ @order_flow_keys ++ ["quantity"]
    )
  end

  defp clear_after_quantity(data) do
    drop_flow_keys(data, @buyer_keys ++ @order_flow_keys ++ ["quantity"])
  end

  defp clear_after_buyer_name(data) do
    drop_flow_keys(data, @buyer_keys ++ @order_flow_keys)
  end

  defp clear_after_email(data) do
    drop_flow_keys(data, ["buyer_email"] ++ @order_flow_keys)
  end

  defp drop_flow_keys(data, keys) when is_map(data), do: Map.drop(data, keys)
  defp drop_flow_keys(_data, _keys), do: %{}

  defp customer_actor(event_id) do
    %{actor_type: :customer_session, actor_id: "whatsapp_customer", allowed_event_ids: [event_id]}
  end

  defp state_data(%Conversation{state_data: data}) when is_map(data), do: data
  defp state_data(_conversation), do: %{}

  defp language(%Conversation{preferred_language: language}) when language in ["af", "en"],
    do: language

  defp language(_conversation), do: "af"

  defp valid_email?(email) when is_binary(email), do: Regex.match?(~r/^[^\s@]+@[^\s@]+$/, email)
  defp valid_email?(_email), do: false

  defp session_ttl_seconds do
    Application.get_env(:fastcheck, :whatsapp_session_ttl_seconds, @session_ttl_seconds)
  end
end
