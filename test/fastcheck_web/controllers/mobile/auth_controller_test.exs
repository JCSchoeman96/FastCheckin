defmodule FastCheckWeb.Mobile.AuthControllerTest do
  use FastCheckWeb.ConnCase, async: true

  alias FastCheck.{Crypto, Repo, Events.Event}

  @credential "super-secret"

  setup do
    # Create a test event for authentication tests
    {:ok, encrypted_secret} = Crypto.encrypt(@credential)

    event =
      %Event{
        name: "Test Event",
        site_url: "https://test.example.com",
        tickera_site_url: "https://test.example.com",
        tickera_api_key_encrypted: "encrypted_key",
        mobile_access_secret_encrypted: encrypted_secret,
        status: "active"
      }
      |> Repo.insert!()

    %{event: event}
  end

  describe "POST /api/v1/mobile/login" do
    test "successfully issues a token for a valid event_id", %{conn: conn, event: event} do
      conn =
        post(conn, ~p"/api/v1/mobile/login", %{
          "event_id" => event.id,
          "credential" => @credential
        })

      assert %{
               "data" => %{
                 "token" => token,
                 "event_id" => event_id,
                 "event_name" => event_name,
                 "expires_in" => expires_in
               },
               "error" => nil
             } = json_response(conn, 200)

      assert is_binary(token)
      assert String.starts_with?(token, "eyJ")
      assert event_id == event.id
      assert event_name == event.name
      assert is_integer(expires_in)
      assert expires_in > 0
    end

    test "successfully issues a token when event_id is a string", %{conn: conn, event: event} do
      conn =
        post(conn, ~p"/api/v1/mobile/login", %{
          "event_id" => Integer.to_string(event.id),
          "credential" => @credential
        })

      assert %{"data" => %{"token" => _token}} = json_response(conn, 200)
    end

    test "rejects missing event_id with 400", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/mobile/login", %{"credential" => @credential})

      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(conn, 400)

      assert message =~ "event_id is required"
    end

    test "rejects invalid event_id format with 400", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/mobile/login", %{
          "event_id" => "not-a-number"
        })

      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(conn, 400)

      assert message =~ "must be a positive integer"
    end

    test "rejects negative event_id with 400", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/mobile/login", %{
          "event_id" => -1,
          "credential" => @credential
        })

      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(conn, 400)

      assert message =~ "must be a positive integer"
    end

    test "rejects zero event_id with 400", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/mobile/login", %{
          "event_id" => 0,
          "credential" => @credential
        })

      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(conn, 400)

      assert message =~ "must be a positive integer"
    end

    test "rejects non-existent event_id with 404", %{conn: conn} do
      non_existent_id = 999_999

      conn =
        post(conn, ~p"/api/v1/mobile/login", %{
          "event_id" => non_existent_id,
          "credential" => @credential
        })

      assert %{"error" => %{"code" => "event_not_found", "message" => message}} =
               json_response(conn, 404)

      assert message =~ "does not exist"
    end

    test "rejects missing credential with 401", %{conn: conn, event: event} do
      conn =
        post(conn, ~p"/api/v1/mobile/login", %{
          "event_id" => event.id
        })

      assert %{"error" => %{"code" => "missing_credential", "message" => message}} =
               json_response(conn, 401)

      assert message =~ "credential"
    end

    test "rejects invalid credential with 403", %{conn: conn, event: event} do
      conn =
        post(conn, ~p"/api/v1/mobile/login", %{
          "event_id" => event.id,
          "credential" => "wrong"
        })

      assert %{"error" => %{"code" => "invalid_credential", "message" => message}} =
               json_response(conn, 403)

      assert message =~ "invalid"
    end

    test "issued token can be verified and contains correct claims", %{conn: conn, event: event} do
      conn =
        post(conn, ~p"/api/v1/mobile/login", %{
          "event_id" => event.id,
          "credential" => @credential
        })

      assert %{"data" => %{"token" => token}} = json_response(conn, 200)

      # Verify the token using the Token module
      assert {:ok, claims} = FastCheck.Mobile.Token.verify_token(token)
      assert claims["event_id"] == event.id
      assert claims["role"] == "scanner"
      assert is_integer(claims["exp"])
      assert is_integer(claims["iat"])
    end
  end
end
