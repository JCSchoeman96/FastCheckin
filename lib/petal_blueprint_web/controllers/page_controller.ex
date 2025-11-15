defmodule PetalBlueprintWeb.PageController do
  use PetalBlueprintWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
