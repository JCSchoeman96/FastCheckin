defmodule FastCheckWeb do
  @moduledoc """
  Wrapper module that exposes the same helpers as `PetalBlueprintWeb` so
  FastCheck-specific LiveViews can use the familiar API while living inside
  their own namespace.
  """

  defmacro __using__(which) when is_atom(which) do
    apply(PetalBlueprintWeb, which, [])
  end
end
