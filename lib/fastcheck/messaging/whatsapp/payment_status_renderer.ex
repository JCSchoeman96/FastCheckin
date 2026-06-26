defmodule FastCheck.Messaging.WhatsApp.PaymentStatusRenderer do
  @moduledoc """
  Customer-safe copy for WhatsApp payment status handoffs.
  """

  @spec payment_link_queued(String.t() | nil) :: String.t()
  def payment_link_queued("en") do
    "Your order is ready for payment. We are sending your secure Paystack payment link now."
  end

  def payment_link_queued(_language) do
    "Jou bestelling is gereed vir betaling. Ons stuur nou jou veilige Paystack-betaalskakel."
  end

  @spec missing_email(String.t() | nil) :: String.t()
  def missing_email("en") do
    "Please send your email address so we can create your secure payment link."
  end

  def missing_email(_language) do
    "Stuur asseblief jou e-posadres sodat ons jou veilige betaalskakel kan skep."
  end

  @spec payment_pending(String.t() | nil) :: String.t()
  def payment_pending("en") do
    "We are checking your payment. Your ticket will be prepared once payment is safely confirmed."
  end

  def payment_pending(_language) do
    "Ons bevestig jou betaling. Jou kaartjie sal voorberei word sodra betaling veilig bevestig is."
  end

  @spec ticket_preparing(String.t() | nil) :: String.t()
  def ticket_preparing("en") do
    "Payment received. Your ticket is being prepared."
  end

  def ticket_preparing(_language) do
    "Betaling ontvang. Jou kaartjie word voorberei."
  end

  @spec manual_review(String.t() | nil) :: String.t()
  def manual_review("en") do
    "Your order needs support review. We will help you from here."
  end

  def manual_review(_language) do
    "Jou bestelling benodig ondersteuning. Ons sal jou van hier af help."
  end

  @spec terminal(String.t() | nil, String.t() | nil) :: String.t()
  def terminal("en", status) do
    "This order is #{status || "not active"}. Please contact support if you need help."
  end

  def terminal(_language, status) do
    "Hierdie bestelling is #{status || "nie aktief nie"}. Kontak asseblief ondersteuning as jy hulp nodig het."
  end
end
