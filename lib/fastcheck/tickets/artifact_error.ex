defmodule FastCheck.Tickets.ArtifactError do
  @moduledoc """
  Customer-safe non-renderable ticket artifact state.

  The full support message remains available as data for renderers, but custom
  inspection only reports fixed operational fields.
  """

  @enforce_keys [:state, :support_message, :http_status_hint]
  defstruct @enforce_keys

  @type state ::
          :not_found
          | :expired_link
          | :ticket_revoked
          | :ticket_not_scannable
          | :ticket_not_ready

  @type t :: %__MODULE__{
          state: state(),
          support_message: String.t(),
          http_status_hint: :not_found | :gone | :ok
        }
end

defimpl Inspect, for: FastCheck.Tickets.ArtifactError do
  def inspect(error, opts) do
    %{
      state: error.state,
      http_status_hint: error.http_status_hint
    }
    |> Inspect.Map.inspect(opts)
  end
end
