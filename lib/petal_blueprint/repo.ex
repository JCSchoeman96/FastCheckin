defmodule PetalBlueprint.Repo do
  use Ecto.Repo,
    otp_app: :petal_blueprint,
    adapter: Ecto.Adapters.Postgres
end
