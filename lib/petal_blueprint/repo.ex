defmodule PetalBlueprint.Repo do
  @moduledoc """
  Central PostgreSQL repository for FastCheck.

  ## Query optimization tips

    * Always use `SELECT *` with `LIMIT` for pagination so PostgreSQL can stop scanning early.
    * Use `FOR UPDATE` on the `attendees` rows selected during check-in to prevent race conditions when multiple scanners operate concurrently.
    * Rely on the `(event_id, ticket_code)` covering index to guarantee single-ticket lookups in <10ms and keep check-in processing within the 50ms budget.

  ## Performance targets

    * Single ticket lookup <10ms
    * Bulk insert 1,000 attendees <2s
    * Check-in processing <50ms end-to-end
    * Stats calculation <20ms
  """

  use Ecto.Repo,
    otp_app: :petal_blueprint,
    adapter: Ecto.Adapters.Postgres
end
