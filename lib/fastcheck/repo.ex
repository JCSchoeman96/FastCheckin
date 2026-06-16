defmodule FastCheck.Repo do
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

  use AshPostgres.Repo,
    otp_app: :fastcheck,
    adapter: Ecto.Adapters.Postgres,
    warn_on_missing_ash_functions?: false

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
