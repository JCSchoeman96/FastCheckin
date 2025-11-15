defmodule PetalBlueprintWeb.PageControllerTest do
  use PetalBlueprintWeb.ConnCase

  test "GET / shows FastCheck dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "FastCheck Dashboard"
  end
end
