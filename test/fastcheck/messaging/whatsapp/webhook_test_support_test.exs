defmodule FastCheck.Messaging.WhatsApp.WebhookTestSupportTest do
  use ExUnit.Case, async: false

  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
  alias FastCheck.Redis.Namespace

  setup do
    previous_namespace = Application.get_env(:fastcheck, :redis_namespace)

    on_exit(fn ->
      if is_nil(previous_namespace) do
        Application.delete_env(:fastcheck, :redis_namespace)
      else
        Application.put_env(:fastcheck, :redis_namespace, previous_namespace)
      end
    end)

    :ok
  end

  test "flush_redis_keys!/0 deletes only keys in the active test namespace" do
    nonce =
      :crypto.strong_rand_bytes(16)
      |> Base.encode16(case: :lower)

    current_namespace = Application.fetch_env!(:fastcheck, :redis_namespace)
    sibling_namespace = "fastcheck:test:foreign-#{nonce}"

    refute sibling_namespace == current_namespace
    refute String.starts_with?(sibling_namespace, current_namespace <> ":")

    current_key = Namespace.key("fastcheck:whatsapp:dedupe:message:current-#{nonce}")
    raw_key = "fastcheck:whatsapp:dedupe:message:raw-foreign-#{nonce}"

    foreign_key =
      sibling_namespace <> ":fastcheck:whatsapp:dedupe:message:foreign-#{nonce}"

    assert Namespace.scoped?(current_key)
    refute Namespace.scoped?(raw_key)
    refute Namespace.scoped?(foreign_key)

    assert :ok = redis_set(current_key, "1")
    assert :ok = redis_set(raw_key, "1")
    assert :ok = redis_set(foreign_key, "1")

    WebhookTestSupport.flush_redis_keys!()

    assert redis_exists?(current_key) == false
    assert redis_exists?(raw_key) == true
    assert redis_exists?(foreign_key) == true

    assert {:ok, _} = Redix.command(FastCheck.Redix, ["DEL", raw_key, foreign_key])
  end

  defp redis_set(key, value) do
    case Redix.command(FastCheck.Redix, ["SET", key, value]) do
      {:ok, "OK"} -> :ok
      other -> flunk("unable to seed redis key #{inspect(key)}: #{inspect(other)}")
    end
  end

  defp redis_exists?(key) do
    case Redix.command(FastCheck.Redix, ["EXISTS", key]) do
      {:ok, 1} -> true
      {:ok, 0} -> false
      other -> flunk("unable to check redis key #{inspect(key)}: #{inspect(other)}")
    end
  end
end
