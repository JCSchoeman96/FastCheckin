defmodule FastCheckWeb.Components.Helpers.ComponentClasses do
  @moduledoc """
  Shared helpers for looking up component CSS class variants.

  The helper centralises the common pattern of mapping a variant key to a
  precomputed class name while allowing callers to pass through custom
  class strings.
  """

  @doc """
  Returns the class associated with the given `key` in `class_map`.

  If the key is not present but is a binary, it is returned directly to
  allow callers to pass custom classes. Otherwise `default` is returned.
  """
  @spec class_for(map(), term(), binary() | nil) :: binary() | nil
  def class_for(class_map, key, default \\ nil) do
    cond do
      is_map_key(class_map, key) -> Map.fetch!(class_map, key)
      is_binary(key) -> key
      true -> default
    end
  end
end
