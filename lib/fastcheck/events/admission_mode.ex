defmodule FastCheck.Events.AdmissionMode do
  @moduledoc """
  Per-event admission semantics for scanners.

  * `session` — track inside state; block entry while marked inside (default).
  * `turnstile` — count valid entries only; do not gate on inside state.
  """

  import Ecto.Query, warn: false

  alias FastCheck.Events.Event
  alias FastCheck.Repo

  @session "session"
  @turnstile "turnstile"
  @valid_modes [@session, @turnstile]

  @spec valid_modes() :: [String.t()]
  def valid_modes, do: @valid_modes

  @spec normalize(term()) :: String.t()
  def normalize(mode) when mode in @valid_modes, do: mode
  def normalize(_), do: @session

  @spec turnstile?(integer()) :: boolean()
  def turnstile?(event_id) when is_integer(event_id) do
    case Repo.one(
           from(e in Event,
             where: e.id == ^event_id,
             select: e.admission_mode
           )
         ) do
      @turnstile -> true
      _ -> false
    end
  end

  def turnstile?(_), do: false
end
