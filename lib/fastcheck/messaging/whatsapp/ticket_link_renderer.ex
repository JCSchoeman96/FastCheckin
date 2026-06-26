defmodule FastCheck.Messaging.WhatsApp.TicketLinkRenderer do
  @moduledoc """
  Customer-safe WhatsApp copy for secure ticket links.
  """

  @spec ticket_link(String.t() | nil, String.t()) :: String.t()
  def ticket_link("en", url) do
    "Your ticket is ready. Open your secure ticket link here: #{url}"
  end

  def ticket_link(_language, url) do
    "Jou kaartjie is gereed. Maak jou veilige kaartjieskakel hier oop: #{url}"
  end

  @spec not_ready(String.t() | nil) :: String.t()
  def not_ready("en"), do: "Your ticket is not ready yet. Please try again shortly."

  def not_ready(_language),
    do: "Jou kaartjie is nog nie gereed nie. Probeer asseblief weer binnekort."

  @spec not_deliverable(String.t() | nil) :: String.t()
  def not_deliverable("en") do
    "We cannot send an active ticket link for this order. Please contact support."
  end

  def not_deliverable(_language) do
    "Ons kan nie 'n aktiewe kaartjieskakel vir hierdie bestelling stuur nie. Kontak asseblief ondersteuning."
  end
end
