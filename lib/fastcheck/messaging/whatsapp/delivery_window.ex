defmodule FastCheck.Messaging.WhatsApp.DeliveryWindow do
  @moduledoc """
  Pure Meta WhatsApp customer-service window checks.
  """

  @window_seconds 24 * 60 * 60

  @spec inside?(DateTime.t() | nil, DateTime.t()) :: boolean()
  def inside?(%DateTime{} = last_message_at, %DateTime{} = now) do
    DateTime.diff(now, last_message_at, :second) <= @window_seconds
  end

  def inside?(_last_message_at, %DateTime{}), do: false
end
