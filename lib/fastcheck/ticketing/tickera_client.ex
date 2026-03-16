defmodule FastCheck.Ticketing.TickeraClient do
  @moduledoc """
  Domain alias for the existing Tickera client.
  """

  defdelegate parse_attendee(ticket), to: FastCheck.TickeraClient
  defdelegate get_event_essentials(site_url, api_key), to: FastCheck.TickeraClient
  defdelegate get_ticket_config(site_url, api_key, ticket_type_id), to: FastCheck.TickeraClient
end
