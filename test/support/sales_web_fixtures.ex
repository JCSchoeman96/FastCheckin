defmodule FastCheckWeb.SalesWebFixtures do
  @moduledoc false

  alias FastCheck.Crypto
  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias FastCheck.SalesCheckoutFixtures, as: SalesFixtures

  @dashboard_username "admin"

  def dashboard_username, do: @dashboard_username

  def authenticated_conn(conn) do
    Plug.Test.init_test_session(conn, %{
      dashboard_authenticated: true,
      dashboard_username: @dashboard_username
    })
  end

  def insert_event!(attrs \\ %{}) do
    api_key = Map.get(attrs, :tickera_api_key, "tickera-api-key")
    mobile_secret = Map.get(attrs, :mobile_secret, "old-scanner-secret")
    {:ok, encrypted_api_key} = Crypto.encrypt(api_key)
    {:ok, encrypted_mobile_secret} = Crypto.encrypt(mobile_secret)

    defaults = %{
      name: "Sales Event #{System.unique_integer([:positive])}",
      site_url: "https://example.com",
      tickera_site_url: "https://example.com",
      tickera_api_key_encrypted: encrypted_api_key,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      mobile_access_secret_encrypted: encrypted_mobile_secret,
      status: "active",
      entrance_name: "Main Gate",
      location: "Main Venue"
    }

    params =
      defaults
      |> Map.merge(attrs)
      |> Map.delete(:tickera_api_key)
      |> Map.delete(:mobile_secret)

    %Event{}
    |> Event.changeset(params)
    |> Repo.insert!()
  end

  def insert_admin_offer!(event_id, opts \\ []) do
    offer =
      SalesFixtures.insert_offer!(Keyword.merge(opts, event_id: event_id, sales_channel: "admin"))

    on_exit = fn -> SalesFixtures.flush_inventory_keys(offer.id) end
    {offer, on_exit}
  end

  def insert_internal_offer!(event_id, opts \\ []) do
    offer =
      SalesFixtures.insert_offer!(
        Keyword.merge(opts, event_id: event_id, sales_channel: "internal")
      )

    on_exit = fn -> SalesFixtures.flush_inventory_keys(offer.id) end
    {offer, on_exit}
  end
end
