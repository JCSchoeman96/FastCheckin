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
      "3. #{Copy.text(language, :resend_ticket)}",
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
    render_offer_options(language, Copy.text(language, :choose_ticket_type), offers)
  end

  @spec confirm_order(String.t() | nil, map()) :: String.t()
  def confirm_order(language, summary) when is_map(summary) do
    buyer_name =
      present_or_fallback(Map.get(summary, :buyer_name), Copy.text(language, :unavailable))

    buyer_email =
      present_or_fallback(
        Map.get(summary, :buyer_email),
        Copy.text(language, :email_not_provided)
      )

    event_label =
      present_or_fallback(Map.get(summary, :event_label), Copy.text(language, :unavailable))

    offer_label =
      present_or_fallback(Map.get(summary, :offer_label), Copy.text(language, :unavailable))

    price = format_price(language, Map.get(summary, :price_cents), Map.get(summary, :currency))
    quantity = Map.get(summary, :quantity)

    total =
      format_total(
        language,
        Map.get(summary, :price_cents),
        quantity,
        Map.get(summary, :currency)
      )

    [
      Copy.text(language, :confirm),
      "#{Copy.text(language, :confirm_name)}: #{buyer_name}",
      "#{Copy.text(language, :confirm_email)}: #{buyer_email}",
      "#{Copy.text(language, :confirm_event)}: #{event_label}",
      "#{Copy.text(language, :confirm_ticket)}: #{offer_label} - #{price}",
      "#{Copy.text(language, :confirm_quantity)}: #{format_quantity(quantity, Copy.text(language, :unavailable))}",
      "#{Copy.text(language, :confirm_total_payable)}: #{total}",
      "",
      Copy.text(language, :confirm_continue_payment),
      "1. OK",
      navigation_lines(language)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @spec quantity_prompt(String.t() | nil) :: String.t()
  def quantity_prompt(language),
    do: ([Copy.text(language, :quantity)] ++ navigation_lines(language)) |> Enum.join("\n")

  @spec buyer_name_prompt(String.t() | nil) :: String.t()
  def buyer_name_prompt(language),
    do: ([Copy.text(language, :buyer_name)] ++ navigation_lines(language)) |> Enum.join("\n")

  @spec email_prompt(String.t() | nil) :: String.t()
  def email_prompt(language),
    do: ([Copy.text(language, :email)] ++ navigation_lines(language)) |> Enum.join("\n")

  @spec resend_name_prompt(String.t() | nil) :: String.t()
  def resend_name_prompt(language),
    do: ([Copy.text(language, :resend_name)] ++ navigation_lines(language)) |> Enum.join("\n")

  @spec resend_email_prompt(String.t() | nil) :: String.t()
  def resend_email_prompt(language),
    do: ([Copy.text(language, :resend_email)] ++ navigation_lines(language)) |> Enum.join("\n")

  @spec resend_otp_prompt(String.t() | nil) :: String.t()
  def resend_otp_prompt(language) do
    ([Copy.text(language, :resend_check_email), Copy.text(language, :resend_enter_otp)] ++
       navigation_lines(language))
    |> Enum.join("\n")
  end

  @spec invalid_resend_email_prompt(String.t() | nil) :: String.t()
  def invalid_resend_email_prompt(language),
    do: Copy.text(language, :resend_invalid_email) <> "\n\n" <> resend_email_prompt(language)

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

    ([title] ++ options ++ navigation_lines(language))
    |> Enum.join("\n")
  end

  defp render_offer_options(language, title, offers) do
    options =
      offers
      |> Enum.take(9)
      |> Enum.with_index(1)
      |> Enum.map(fn {offer, index} ->
        "#{index}. #{Map.fetch!(offer, :label)} - #{format_price(language, Map.get(offer, :price_cents), Map.get(offer, :currency))}"
      end)

    ([title] ++ options ++ navigation_lines(language))
    |> Enum.join("\n")
  end

  defp back_line(language), do: "0. #{Copy.text(language, :back)}"

  defp restart_line(language), do: "#. #{Copy.text(language, :restart_main_menu)}"

  defp navigation_lines(language), do: [back_line(language), restart_line(language)]

  defp format_price(_language, cents, currency) when is_integer(cents) and cents >= 0 do
    case normalize_currency(currency) do
      "ZAR" -> "R#{format_cents(cents)}"
      "" -> format_cents(cents)
      currency -> "#{currency} #{format_cents(cents)}"
    end
  end

  defp format_price(language, _cents, _currency), do: unavailable_price(language)

  defp format_total(language, cents, quantity, currency)
       when is_integer(cents) and cents >= 0 and is_integer(quantity) and quantity > 0 do
    format_price(language, cents * quantity, currency)
  end

  defp format_total(language, _cents, _quantity, _currency), do: unavailable_price(language)

  defp format_cents(cents) do
    whole = div(cents, 100)
    remainder = rem(cents, 100)

    if remainder == 0 do
      Integer.to_string(whole)
    else
      "#{whole}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
    end
  end

  defp normalize_currency(currency) when is_binary(currency) do
    currency
    |> String.trim()
    |> String.upcase()
  end

  defp normalize_currency(_currency), do: ""

  defp present_or_fallback(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      value -> value
    end
  end

  defp present_or_fallback(_value, fallback), do: fallback

  defp format_quantity(quantity, _fallback) when is_integer(quantity),
    do: Integer.to_string(quantity)

  defp format_quantity(quantity, fallback), do: present_or_fallback(quantity, fallback)

  defp unavailable_price(language), do: Copy.text(language, :price_unavailable)
end
