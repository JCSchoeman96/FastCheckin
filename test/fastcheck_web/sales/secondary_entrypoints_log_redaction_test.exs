defmodule FastCheckWeb.Sales.SecondaryEntrypointsLogRedactionTest do
  use FastCheck.DataCase, async: false

  import ExUnit.CaptureLog

  alias FastCheck.Sales.SecondaryEntrypoints
  alias FastCheckWeb.SalesWebFixtures, as: WebFixtures

  @user %{id: "admin", username: "admin"}

  setup do
    event = WebFixtures.insert_event!()

    offer =
      FastCheck.SalesCheckoutFixtures.insert_offer!(event_id: event.id, sales_channel: "admin")

    on_exit(fn -> FastCheck.SalesCheckoutFixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer}
  end

  test "adapter checkout logs do not include buyer PII", %{offer: offer} do
    idem = SecondaryEntrypoints.generate_idempotency_key()

    params = %{
      "ticket_offer_id" => to_string(offer.id),
      "quantity" => "1",
      "buyer_name" => "Secret Buyer",
      "buyer_email" => "secret@example.com",
      "buyer_phone" => "+27111111111"
    }

    log =
      capture_log(fn ->
        assert {:ok, _} =
                 SecondaryEntrypoints.start_admin_checkout(
                   @user,
                   offer.event_id,
                   params,
                   idem
                 )
      end)

    refute log =~ "Secret Buyer"
    refute log =~ "secret@example.com"
    refute log =~ "+27111111111"
    refute log =~ idem
  end
end
