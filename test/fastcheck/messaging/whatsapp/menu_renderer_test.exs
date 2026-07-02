defmodule FastCheck.Messaging.WhatsApp.MenuRendererTest do
  use ExUnit.Case, async: true

  alias FastCheck.Messaging.WhatsApp.MenuRenderer

  describe "language_prompt/0" do
    test "renders the Afrikaans-first language prompt" do
      assert """
             Welkom by FastCheck Tickets.
             1. Afrikaans
             2. English
             """ = MenuRenderer.language_prompt()

      refute MenuRenderer.language_prompt() =~ "#."
    end
  end

  describe "main_menu/1" do
    test "renders number-only main menu copy in Afrikaans by default" do
      body = MenuRenderer.main_menu("af")

      assert body =~ "1. Koop kaartjies"
      assert body =~ "2. Hulp"
      assert body =~ "3. Stuur my kaartjie weer"
      assert body =~ "0. Terug"
      refute body =~ "ticket_issued"
      refute body =~ "payment_url"
    end

    test "renders number-only main menu copy in English" do
      body = MenuRenderer.main_menu("en")

      assert body =~ "1. Buy tickets"
      assert body =~ "2. Help"
      assert body =~ "3. Re-send my ticket"
      assert body =~ "0. Back"
    end
  end

  describe "dynamic menus" do
    test "renders event options without exposing raw internal labels" do
      body =
        MenuRenderer.event_menu("af", [
          %{id: 101, label: "Voelgoed Live"},
          %{id: 202, label: "Somer Fees"}
        ])

      assert body =~ "1. Voelgoed Live"
      assert body =~ "2. Somer Fees"
      assert body =~ "0. Terug"
      assert body =~ "#. Terug na hoof kieslys (Kanselleer en begin oor)"
      refute body =~ "101"
      refute body =~ "202"
      refute body =~ "R999"
      refute body =~ "restart"
    end

    test "renders ZAR prices next to offer options without exposing offer ids" do
      body =
        MenuRenderer.offer_menu("af", [
          %{id: 101, label: "General Admission", price_cents: 99_900, currency: "ZAR"},
          %{id: 202, label: "VIP", price_cents: 199_950, currency: "ZAR"}
        ])

      assert body =~ "1. General Admission - R999"
      assert body =~ "2. VIP - R1999.50"
      assert body =~ "0. Terug"
      assert body =~ "#. Terug na hoof kieslys (Kanselleer en begin oor)"
      refute body =~ "101"
      refute body =~ "202"
    end

    test "renders active flow prompts with back and restart navigation" do
      quantity = MenuRenderer.quantity_prompt("af")
      buyer_name = MenuRenderer.buyer_name_prompt("af")
      email = MenuRenderer.email_prompt("af")
      resend_name = MenuRenderer.resend_name_prompt("af")
      resend_email = MenuRenderer.resend_email_prompt("af")
      resend_otp = MenuRenderer.resend_otp_prompt("af")

      for body <- [quantity, buyer_name, email, resend_name, resend_email, resend_otp] do
        assert body =~ "0. Terug"
        assert body =~ "#. Terug na hoof kieslys (Kanselleer en begin oor)"
        refute body =~ "restart"
      end

      english_email = MenuRenderer.email_prompt("en")

      assert english_email =~ "0. Back"
      assert english_email =~ "#. Back to main menu (Cancel and start over)"

      assert MenuRenderer.resend_name_prompt("en") =~ "name"
      assert MenuRenderer.resend_email_prompt("en") =~ "email"
      assert MenuRenderer.resend_otp_prompt("en") =~ "verification code"
      assert MenuRenderer.invalid_resend_email_prompt("en") =~ "valid email"
    end

    test "renders explicit zero ZAR price as R0" do
      body =
        MenuRenderer.offer_menu("af", [
          %{id: 101, label: "Comp", price_cents: 0, currency: "ZAR"}
        ])

      assert body =~ "1. Comp - R0"
    end

    test "renders invalid prices as unavailable without implying free tickets" do
      af_body =
        MenuRenderer.offer_menu("af", [
          %{id: 101, label: "Broken", price_cents: nil, currency: "ZAR"},
          %{id: 202, label: "Negative", price_cents: -100, currency: "ZAR"}
        ])

      en_body =
        MenuRenderer.offer_menu("en", [
          %{id: 303, label: "Broken", price_cents: "1000", currency: "ZAR"}
        ])

      assert af_body =~ "1. Broken - Prys nie beskikbaar"
      assert af_body =~ "2. Negative - Prys nie beskikbaar"
      assert en_body =~ "1. Broken - Price unavailable"
      refute af_body =~ "R0"
      refute en_body =~ "R0"
    end

    test "renders non-ZAR prices with currency code fallback" do
      body =
        MenuRenderer.offer_menu("en", [
          %{id: 101, label: "International", price_cents: 99_950, currency: "USD"}
        ])

      assert body =~ "1. International - USD 999.50"
    end

    test "renders checkout pending copy without Paystack or ticket promises" do
      body = MenuRenderer.awaiting_payment("af")

      assert body =~ "betaling"
      refute body =~ "Paystack"
      refute body =~ "https://"
      refute body =~ "kaartjie is gereed"
    end
  end

  describe "invalid_input/2" do
    test "adds a concise correction to the current menu" do
      body = MenuRenderer.invalid_input("en", "1. Buy tickets")

      assert body =~ "Please reply with one of the numbers shown."
      assert body =~ "1. Buy tickets"
    end
  end

  describe "confirm_order/2" do
    test "renders Afrikaans order summary with email present" do
      body =
        MenuRenderer.confirm_order("af", %{
          buyer_name: "Jan Burger",
          buyer_email: "jan@example.com",
          event_label: "Voelgoed Live",
          offer_label: "General",
          price_cents: 1_000,
          currency: "ZAR",
          quantity: 2
        })

      assert body =~ "Bevestig jou bestelling:"
      assert body =~ "Naam: Jan Burger"
      assert body =~ "E-pos: jan@example.com"
      assert body =~ "Geleentheid: Voelgoed Live"
      assert body =~ "Kaartjie: General - R10"
      assert body =~ "Aantal: 2"
      assert body =~ "Totaal betaalbaar: R20"
      assert body =~ "Is hierdie korrek? Gaan voort na betaling."
      assert body =~ "1. OK"
      assert body =~ "0. Terug"
      assert body =~ "#. Terug na hoof kieslys (Kanselleer en begin oor)"
      refute body =~ "restart"
    end

    test "renders English order summary with skipped email" do
      body =
        MenuRenderer.confirm_order("en", %{
          buyer_name: "Jan Burger",
          buyer_email: nil,
          event_label: "Voelgoed Live",
          offer_label: "General",
          price_cents: 1_000,
          currency: "ZAR",
          quantity: 2
        })

      assert body =~ "Confirm your order:"
      assert body =~ "Name: Jan Burger"
      assert body =~ "Email: Not provided"
      assert body =~ "Event: Voelgoed Live"
      assert body =~ "Ticket: General - R10"
      assert body =~ "Quantity: 2"
      assert body =~ "Total payable: R20"
      assert body =~ "Is this correct? Continue to payment."
      assert body =~ "1. OK"
      assert body =~ "0. Back"
      assert body =~ "#. Back to main menu (Cancel and start over)"
    end

    test "renders invalid prices as unavailable without implying free tickets" do
      af_body =
        MenuRenderer.confirm_order("af", %{
          buyer_name: "Jan Burger",
          buyer_email: "jan@example.com",
          event_label: "Voelgoed Live",
          offer_label: "Broken",
          price_cents: nil,
          currency: "ZAR",
          quantity: 2
        })

      en_body =
        MenuRenderer.confirm_order("en", %{
          buyer_name: "Jan Burger",
          buyer_email: "jan@example.com",
          event_label: "Voelgoed Live",
          offer_label: "Broken",
          price_cents: "1000",
          currency: "ZAR",
          quantity: 2
        })

      assert af_body =~ "Kaartjie: Broken - Prys nie beskikbaar"
      assert af_body =~ "Totaal betaalbaar: Prys nie beskikbaar"
      assert en_body =~ "Ticket: Broken - Price unavailable"
      assert en_body =~ "Total payable: Price unavailable"
      refute af_body =~ "R0"
      refute en_body =~ "R0"
    end

    test "renders neutral fallback copy for missing non-price fields" do
      body =
        MenuRenderer.confirm_order("en", %{
          buyer_name: "",
          buyer_email: "",
          event_label: nil,
          offer_label: 123,
          price_cents: 1_000,
          currency: "ZAR",
          quantity: 1
        })

      assert body =~ "Name: Not available"
      assert body =~ "Email: Not provided"
      assert body =~ "Event: Not available"
      assert body =~ "Ticket: Not available - R10"
    end

    test "computes total with integer cents math and existing money formatting" do
      body =
        MenuRenderer.confirm_order("en", %{
          buyer_name: "Jan Burger",
          buyer_email: "jan@example.com",
          event_label: "Voelgoed Live",
          offer_label: "VIP",
          price_cents: 199_950,
          currency: "ZAR",
          quantity: 2
        })

      assert body =~ "Ticket: VIP - R1999.50"
      assert body =~ "Total payable: R3999"
      refute body =~ "R3999.00"
    end
  end
end
