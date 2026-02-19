defmodule FastCheckWeb.ErrorJSONTest do
  use FastCheckWeb.ConnCase, async: true

  test "renders 404" do
    assert FastCheckWeb.ErrorJSON.render("404.json", %{}) == %{
             data: nil,
             error: %{code: "HTTP_ERROR", message: "Not Found"}
           }
  end

  test "renders 500" do
    assert FastCheckWeb.ErrorJSON.render("500.json", %{}) ==
             %{
               data: nil,
               error: %{code: "HTTP_ERROR", message: "Internal Server Error"}
             }
  end
end
