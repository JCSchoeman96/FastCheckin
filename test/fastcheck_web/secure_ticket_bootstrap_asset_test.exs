defmodule FastCheckWeb.SecureTicketBootstrapAssetTest do
  use ExUnit.Case, async: true

  @bootstrap_path Path.expand("../../assets/js/secure_ticket_bootstrap.js", __DIR__)
  @app_js_path Path.expand("../../assets/js/app.js", __DIR__)

  test "secure_ticket_bootstrap.js is imported by app.js and follows security sequence" do
    app_js = File.read!(@app_js_path)
    bootstrap_js = File.read!(@bootstrap_path)

    assert app_js =~ "secure_ticket_bootstrap.js"
    assert bootstrap_js =~ "window.location.hash"
    assert bootstrap_js =~ "history.replaceState"
    assert bootstrap_js =~ "/t/session"
    assert bootstrap_js =~ "delivery_token"
    assert bootstrap_js =~ "location.replace"

    replace_idx = :binary.match(bootstrap_js, "history.replaceState") |> elem(0)
    fetch_idx = :binary.match(bootstrap_js, "fetch(\"/t/session\"") |> elem(0)
    assert replace_idx < fetch_idx

    for forbidden <- ~w(localStorage sessionStorage document.cookie console.log console.debug) do
      refute bootstrap_js =~ forbidden
    end
  end
end
