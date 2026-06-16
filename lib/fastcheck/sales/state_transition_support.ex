defmodule FastCheck.Sales.StateTransitionSupport do
  @moduledoc false

  alias Ash.Changeset
  alias FastCheck.Observability.Redactor
  alias FastCheck.Sales.StateTransition

  @spec record!(
          %{
            entity_type: String.t(),
            entity_id: String.t(),
            from_state: String.t() | nil,
            to_state: String.t(),
            reason: String.t() | nil,
            metadata: map(),
            correlation_id: String.t() | nil,
            idempotency_key: String.t() | nil,
            source: String.t() | nil
          },
          map()
        ) :: {:ok, struct()} | {:error, term()}
  def record!(attrs, context) do
    actor = Map.get(context, :actor) || %{actor_type: :system, actor_id: "system"}

    actor_type = to_string(Map.get(actor, :actor_type, :system))

    actor_id =
      Map.get(actor, :actor_id) || Map.get(actor, :user_id) ||
        Map.get(actor, "actor_id") || Map.get(actor, "user_id")

    create_attrs = %{
      entity_type: attrs.entity_type,
      entity_id: attrs.entity_id,
      from_state: Map.get(attrs, :from_state),
      to_state: attrs.to_state,
      reason: Map.get(attrs, :reason),
      actor_type: actor_type,
      actor_id: actor_id,
      metadata: sanitize_metadata(Map.get(attrs, :metadata, %{})),
      correlation_id: Map.get(attrs, :correlation_id),
      idempotency_key: Map.get(attrs, :idempotency_key),
      source: Map.get(attrs, :source)
    }

    StateTransition
    |> Changeset.for_create(:record_transition, create_attrs, actor: actor)
    |> Ash.create(authorize?: false)
  end

  defp sanitize_metadata(metadata) when is_map(metadata) do
    Redactor.safe_metadata(metadata)
  end
end
