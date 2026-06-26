defmodule FastCheck.Messaging.WhatsApp.MenuRenderer do
  @moduledoc """
  Renders customer-facing number-only WhatsApp menus.
  """

  alias FastCheck.Messaging.WhatsApp.Copy

  @spec language_prompt() :: String.t()
  def language_prompt do
    """
    Welkom by FastCheck Tickets.
    1. Afrikaans
    2. English
    """
  end

  @spec main_menu(String.t() | nil) :: String.t()
  def main_menu(language) do
    [
      Copy.text(language, :main_menu_title),
      "1. #{Copy.text(language, :buy_tickets)}",
      "2. #{Copy.text(language, :help)}",
      "0. #{Copy.text(language, :back)}"
    ]
    |> Enum.join("\n")
  end

  @spec event_menu(String.t() | nil, [map()]) :: String.t()
  def event_menu(language, events) do
    render_options(language, Copy.text(language, :choose_event), events)
  end

  @spec offer_menu(String.t() | nil, [map()]) :: String.t()
  def offer_menu(language, offers) do
    render_options(language, Copy.text(language, :choose_ticket_type), offers)
  end

  @spec quantity_prompt(String.t() | nil) :: String.t()
  def quantity_prompt(language),
    do: Copy.text(language, :quantity) <> "\n0. #{Copy.text(language, :back)}"

  @spec buyer_name_prompt(String.t() | nil) :: String.t()
  def buyer_name_prompt(language), do: Copy.text(language, :buyer_name)

  @spec email_prompt(String.t() | nil) :: String.t()
  def email_prompt(language), do: Copy.text(language, :email)

  @spec awaiting_payment(String.t() | nil) :: String.t()
  def awaiting_payment(language), do: Copy.text(language, :awaiting_payment)

  @spec payment_pending(String.t() | nil) :: String.t()
  def payment_pending(language), do: Copy.text(language, :payment_pending)

  @spec no_events(String.t() | nil) :: String.t()
  def no_events(language), do: Copy.text(language, :no_events)

  @spec help(String.t() | nil) :: String.t()
  def help(language), do: Copy.text(language, :support)

  @spec cancelled(String.t() | nil) :: String.t()
  def cancelled(language), do: Copy.text(language, :cancelled)

  @spec invalid_input(String.t() | nil, String.t()) :: String.t()
  def invalid_input(language, menu_body) do
    Copy.text(language, :invalid) <> "\n\n" <> menu_body
  end

  defp render_options(language, title, rows) do
    options =
      rows
      |> Enum.take(9)
      |> Enum.with_index(1)
      |> Enum.map(fn {row, index} -> "#{index}. #{Map.fetch!(row, :label)}" end)

    ([title] ++ options ++ ["0. #{Copy.text(language, :back)}"])
    |> Enum.join("\n")
  end
end
