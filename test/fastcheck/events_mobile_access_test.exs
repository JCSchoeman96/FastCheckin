defmodule FastCheck.EventsMobileAccessTest do
  use FastCheck.DataCase, async: true

  alias FastCheck.Crypto
  alias FastCheck.Events
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  test "update_event/2 rotates mobile access code when provided" do
    event = insert_event!("old-secret")

    assert :ok = Events.verify_mobile_access_secret(event, "old-secret")

    assert {:ok, updated} =
             Events.update_event(event.id, %{
               "mobile_access_code" => "new-secret"
             })

    assert :ok = Events.verify_mobile_access_secret(updated, "new-secret")

    assert {:error, :invalid_credential} =
             Events.verify_mobile_access_secret(updated, "old-secret")
  end

  test "update_event/2 keeps current mobile access code when field is blank" do
    event = insert_event!("still-secret")

    assert {:ok, updated} =
             Events.update_event(event.id, %{
               "mobile_access_code" => "   "
             })

    assert :ok = Events.verify_mobile_access_secret(updated, "still-secret")
  end

  defp insert_event!(mobile_secret) do
    api_key = "api-#{System.unique_integer([:positive])}"
    {:ok, encrypted_api_key} = Crypto.encrypt(api_key)
    {:ok, encrypted_mobile_secret} = Crypto.encrypt(mobile_secret)

    %Event{}
    |> Event.changeset(%{
      name: "Event #{System.unique_integer([:positive])}",
      site_url: "https://example.com",
      tickera_site_url: "https://example.com",
      tickera_api_key_encrypted: encrypted_api_key,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      mobile_access_secret_encrypted: encrypted_mobile_secret,
      status: "active",
      entrance_name: "Main Entrance"
    })
    |> Repo.insert!()
  end
end
