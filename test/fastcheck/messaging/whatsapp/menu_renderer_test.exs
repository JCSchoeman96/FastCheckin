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
    end
  end

  describe "main_menu/1" do
    test "renders number-only main menu copy in Afrikaans by default" do
      body = MenuRenderer.main_menu("af")

      assert body =~ "1. Koop kaartjies"
      assert body =~ "2. Hulp"
      assert body =~ "0. Terug"
      refute body =~ "ticket_issued"
      refute body =~ "payment_url"
    end

    test "renders number-only main menu copy in English" do
      body = MenuRenderer.main_menu("en")

      assert body =~ "1. Buy tickets"
      assert body =~ "2. Help"
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
      refute body =~ "101"
      refute body =~ "202"
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
end
