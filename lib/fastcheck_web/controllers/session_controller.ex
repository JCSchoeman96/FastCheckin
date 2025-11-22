defmodule FastCheckWeb.SessionController do
  @moduledoc """
  Handles simple dashboard session authentication using configured credentials.
  """

  use FastCheckWeb, :controller

  import Phoenix.Component, only: [to_form: 2]

  @session_key :dashboard_authenticated
  @session_username_key :dashboard_username

  def new(conn, params) do
    render(conn, :new,
      form: login_form(),
      redirect_to: params["redirect_to"],
      error_message: nil
    )
  end

  def create(conn, %{"session" => session_params} = params) do
    with %{"username" => username, "password" => password} <- session_params do
      if valid_credentials?(username, password) do
        redirect_to = params["redirect_to"] || ~p"/"

        conn
        |> put_session(@session_key, true)
        |> put_session(@session_username_key, username)
        |> redirect(to: redirect_to)
      else
        conn
        |> put_status(:unauthorized)
        |> render(:new,
          form: login_form(session_params),
          redirect_to: params["redirect_to"],
          error_message: "Invalid credentials"
        )
      end
    else
      _ ->
        render_invalid_payload(conn)
    end
  end

  def create(conn, _params) do
    render_invalid_payload(conn)
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login")
  end

  defp login_form(params \ %{"username" => "", "password" => ""}) do
    to_form(params, as: "session")
  end

  defp valid_credentials?(username, password) when is_binary(username) and is_binary(password) do
    %{username: configured_username, password: configured_password} =
      Application.fetch_env!(:fastcheck, :dashboard_auth)

    Plug.Crypto.secure_compare(username, configured_username) and
      Plug.Crypto.secure_compare(password, configured_password)
  end

  defp valid_credentials?(_, _), do: false

  defp render_invalid_payload(conn) do
    conn
    |> put_status(:bad_request)
    |> render(:new, form: login_form(), redirect_to: nil, error_message: "Invalid login payload")
  end
end
