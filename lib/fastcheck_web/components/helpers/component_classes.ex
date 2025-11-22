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
  def class_for(class_map, key, default \ nil)

  def class_for(class_map, key, default) when is_map_key(class_map, key),
    do: Map.fetch!(class_map, key)

  def class_for(_class_map, key, _default) when is_binary(key), do: key
  def class_for(_class_map, _key, default), do: default
end
