defmodule FastCheck.Events.AdmissionModeTest do
  use ExUnit.Case, async: true

  alias FastCheck.Events.Event

  @valid_attrs %{
    name: "Admission Mode Test",
    site_url: "https://example.test",
    tickera_site_url: "https://example.test",
    tickera_api_key_encrypted: "encrypted-key",
    mobile_access_secret_encrypted: "encrypted-secret"
  }

  test "session is the default and turnstile is accepted" do
    default = changeset(%{})
    turnstile = changeset(%{admission_mode: "turnstile"})

    assert Ecto.Changeset.get_field(default, :admission_mode) == "session"
    assert turnstile.valid?
    assert Ecto.Changeset.get_field(turnstile, :admission_mode) == "turnstile"
  end

  test "rejects unsupported admission modes" do
    changeset = changeset(%{admission_mode: "door"})

    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :admission_mode)
  end

  defp changeset(attrs), do: Event.changeset(%Event{}, Map.merge(@valid_attrs, attrs))
end
