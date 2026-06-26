defmodule FastCheck.Messaging.WhatsApp.Copy do
  @moduledoc """
  Customer-facing copy for the VS-18 WhatsApp number-only flow.
  """

  @spec text(String.t(), atom()) :: String.t()
  def text("en", key), do: en(key)
  def text(_language, key), do: af(key)

  defp af(:main_menu_title), do: "Kies 'n opsie:"
  defp af(:buy_tickets), do: "Koop kaartjies"
  defp af(:help), do: "Hulp"
  defp af(:back), do: "Terug"
  defp af(:choose_event), do: "Kies 'n geleentheid:"
  defp af(:choose_ticket_type), do: "Kies 'n kaartjie tipe:"
  defp af(:quantity), do: "Hoeveel kaartjies wil jy koop?"
  defp af(:buyer_name), do: "Stuur asseblief jou naam."
  defp af(:email), do: "Stuur jou e-posadres, of antwoord 1 om oor te slaan."
  defp af(:confirm), do: "Bevestig jou bestelling:"

  defp af(:awaiting_payment),
    do: "Dankie. Jou bestelling is begin. Die betalingstap word voorberei."

  defp af(:payment_pending),
    do: "Ons bevestig jou betaling. Ons sal jou kaartjies voorberei sodra dit veilig bevestig is."

  defp af(:invalid), do: "Antwoord asseblief met een van die nommers hier onder."

  defp af(:no_events),
    do: "Daar is nie nou kaartjies beskikbaar nie. Probeer asseblief later weer."

  defp af(:support),
    do: "Antwoord met 1 om kaartjies te koop, of kontak ondersteuning as jy hulp nodig het."

  defp af(:cancelled), do: "Die gesprek is gekanselleer. Antwoord # om weer te begin."
  defp af(_key), do: "Antwoord asseblief met 'n geldige opsie."

  defp en(:main_menu_title), do: "Choose an option:"
  defp en(:buy_tickets), do: "Buy tickets"
  defp en(:help), do: "Help"
  defp en(:back), do: "Back"
  defp en(:choose_event), do: "Choose an event:"
  defp en(:choose_ticket_type), do: "Choose a ticket type:"
  defp en(:quantity), do: "How many tickets do you want to buy?"
  defp en(:buyer_name), do: "Please send your name."
  defp en(:email), do: "Send your email address, or reply 1 to skip."
  defp en(:confirm), do: "Confirm your order:"

  defp en(:awaiting_payment),
    do: "Thank you. Your order has started. The payment step is being prepared."

  defp en(:payment_pending),
    do:
      "We are confirming your payment. We will prepare your tickets once it is safely confirmed."

  defp en(:invalid), do: "Please reply with one of the numbers shown."
  defp en(:no_events), do: "No tickets are available right now. Please try again later."
  defp en(:support), do: "Reply with 1 to buy tickets, or contact support if you need help."
  defp en(:cancelled), do: "The conversation has been cancelled. Reply # to start again."
  defp en(_key), do: "Please reply with a valid option."
end
