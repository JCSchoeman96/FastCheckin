defmodule FastCheck.Messaging.WhatsApp.Copy do
  @moduledoc """
  Customer-facing copy for the VS-18 WhatsApp number-only flow.
  """

  @spec text(String.t(), atom()) :: String.t()
  def text("en", key), do: en(key)
  def text(_language, key), do: af(key)

  defp af(:main_menu_title), do: "Kies 'n opsie:"
  defp af(:buy_tickets), do: "Koop kaartjies"
  defp af(:resend_ticket), do: "Stuur my kaartjie weer"
  defp af(:help), do: "Hulp"
  defp af(:back), do: "Terug"
  defp af(:restart_main_menu), do: "Terug na hoof kieslys (Kanselleer en begin oor)"
  defp af(:choose_event), do: "Kies 'n geleentheid:"
  defp af(:choose_ticket_type), do: "Kies 'n kaartjie tipe:"
  defp af(:quantity), do: "Hoeveel kaartjies wil jy koop?"
  defp af(:buyer_name), do: "Stuur asseblief jou naam."
  defp af(:email), do: "Stuur jou e-posadres, of antwoord 1 om oor te slaan."
  defp af(:resend_name), do: "Stuur asseblief die naam wat vir die kaartjiebestelling gebruik is."

  defp af(:resend_email),
    do: "Stuur asseblief die e-posadres wat vir die kaartjiebestelling gebruik is."

  defp af(:resend_invalid_email), do: "Stuur asseblief 'n geldige e-posadres."

  defp af(:resend_check_email),
    do: "As die besonderhede ooreenstem, stuur ons 'n verifikasiekode per e-pos."

  defp af(:resend_enter_otp),
    do: "Gaan asseblief jou e-pos na en stuur die verifikasiekode hier."

  defp af(:resend_otp_invalid),
    do: "Daardie kode is ongeldig of het verval. Gaan asseblief die kode na en probeer weer."

  defp af(:resend_otp_locked),
    do: "Te veel pogings. Wag asseblief voor jy weer probeer, of kontak ondersteuning."

  defp af(:resend_otp_verified),
    do: "Verifikasie voltooi. Ons maak jou kaartjie-herstuur gereed."

  defp af(:resend_delivery_pending),
    do: "Verifikasie voltooi. Ons maak jou kaartjie-herstuur gereed."

  defp af(:confirm), do: "Bevestig jou bestelling:"
  defp af(:confirm_name), do: "Naam"
  defp af(:confirm_email), do: "E-pos"
  defp af(:confirm_event), do: "Geleentheid"
  defp af(:confirm_ticket), do: "Kaartjie"
  defp af(:confirm_quantity), do: "Aantal"
  defp af(:confirm_total_payable), do: "Totaal betaalbaar"
  defp af(:confirm_continue_payment), do: "Is hierdie korrek? Gaan voort na betaling."
  defp af(:email_not_provided), do: "Nie verskaf nie"
  defp af(:unavailable), do: "Nie beskikbaar"
  defp af(:price_unavailable), do: "Prys nie beskikbaar"

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
  defp en(:resend_ticket), do: "Re-send my ticket"
  defp en(:help), do: "Help"
  defp en(:back), do: "Back"
  defp en(:restart_main_menu), do: "Back to main menu (Cancel and start over)"
  defp en(:choose_event), do: "Choose an event:"
  defp en(:choose_ticket_type), do: "Choose a ticket type:"
  defp en(:quantity), do: "How many tickets do you want to buy?"
  defp en(:buyer_name), do: "Please send your name."
  defp en(:email), do: "Send your email address, or reply 1 to skip."
  defp en(:resend_name), do: "Please send the name used for the ticket order."
  defp en(:resend_email), do: "Please send the email address used for the ticket order."
  defp en(:resend_invalid_email), do: "Please send a valid email address."

  defp en(:resend_check_email),
    do: "If the details match, we will send a verification code by email."

  defp en(:resend_enter_otp),
    do: "Please check your email and send the verification code here."

  defp en(:resend_otp_invalid),
    do: "That code is invalid or expired. Please check the code and try again."

  defp en(:resend_otp_locked),
    do: "Too many attempts. Please wait before trying again or contact support."

  defp en(:resend_otp_verified),
    do: "Verification complete. We are preparing your ticket resend."

  defp en(:resend_delivery_pending),
    do: "Verification complete. We are preparing your ticket resend."

  defp en(:confirm), do: "Confirm your order:"
  defp en(:confirm_name), do: "Name"
  defp en(:confirm_email), do: "Email"
  defp en(:confirm_event), do: "Event"
  defp en(:confirm_ticket), do: "Ticket"
  defp en(:confirm_quantity), do: "Quantity"
  defp en(:confirm_total_payable), do: "Total payable"
  defp en(:confirm_continue_payment), do: "Is this correct? Continue to payment."
  defp en(:email_not_provided), do: "Not provided"
  defp en(:unavailable), do: "Not available"
  defp en(:price_unavailable), do: "Price unavailable"

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
