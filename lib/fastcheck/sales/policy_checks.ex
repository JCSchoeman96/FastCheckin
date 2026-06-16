defmodule FastCheck.Sales.PolicyChecks do
  @moduledoc """
  Minimal Ash policy checks for the Sales policy foundation.

  These checks only inspect the Ash actor and produce event-scope filters. They
  must not call Repo, external services, caches, Redis, or workflow code.
  """

  defmodule ActorTypeIn do
    @moduledoc false
    use Ash.Policy.SimpleCheck

    def describe(opts), do: "actor_type in #{inspect(Keyword.fetch!(opts, :actor_types))}"

    def match?(%{actor_type: actor_type}, _context, opts) do
      actor_type in Keyword.fetch!(opts, :actor_types)
    end

    def match?(_, _context, _opts), do: false
  end

  defmodule EventAllowed do
    @moduledoc false
    use Ash.Policy.FilterCheck

    def describe(opts) do
      case Keyword.get(opts, :relationship_path, []) do
        [] -> "event_id is allowed for actor"
        path -> "#{Enum.join(path, ".")}.event_id is allowed for actor"
      end
    end

    def filter(%{actor_type: actor_type, allowed_event_ids: allowed_event_ids}, _context, opts)
        when is_list(allowed_event_ids) do
      actor_types = Keyword.get(opts, :actor_types, [:admin, :operator])

      if actor_type in actor_types do
        case Keyword.get(opts, :relationship_path, []) do
          [] -> expr(event_id in ^allowed_event_ids)
          path -> expr(^ref(path, :event_id) in ^allowed_event_ids)
        end
      else
        expr(false)
      end
    end

    def filter(_actor, _context, _opts), do: expr(false)
  end
end
