defmodule FastCheck.Sales do
  @moduledoc """
  Empty Ash domain shell for FastCheck Sales.

  VS-01A only establishes the Sales Ash boundary. Sales resources and durable
  business state are added by later slices.
  """

  use Ash.Domain, otp_app: :fastcheck

  resources do
  end
end
