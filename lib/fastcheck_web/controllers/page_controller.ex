defmodule FastCheckWeb.PageController do
  use FastCheckWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
