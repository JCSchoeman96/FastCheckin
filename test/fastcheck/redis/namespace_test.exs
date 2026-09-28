defmodule FastCheck.Redis.NamespaceTest do
  use ExUnit.Case, async: false

  alias FastCheck.Redis.Namespace

  setup do
    previous = Application.get_env(:fastcheck, :redis_namespace)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:fastcheck, :redis_namespace)
      else
        Application.put_env(:fastcheck, :redis_namespace, previous)
      end
    end)

    :ok
  end

  test "keeps legacy production keys when no namespace is configured" do
    Application.delete_env(:fastcheck, :redis_namespace)

    assert Namespace.key("sales:hold:FC-123") == "sales:hold:FC-123"
    assert Namespace.pattern("sales:hold:*") == "sales:hold:*"
  end

  test "prefixes keys and patterns once when a namespace is configured" do
    Application.put_env(:fastcheck, :redis_namespace, "fastcheck:test:run-123")

    assert Namespace.key("sales:hold:FC-123") == "fastcheck:test:run-123:sales:hold:FC-123"

    assert Namespace.key("fastcheck:test:run-123:sales:hold:FC-123") ==
             "fastcheck:test:run-123:sales:hold:FC-123"

    assert Namespace.pattern("sales:hold:*") == "fastcheck:test:run-123:sales:hold:*"

    assert Namespace.command(["KEYS", "sales:hold:*"]) ==
             ["KEYS", "fastcheck:test:run-123:sales:hold:*"]
  end

  test "rejects cleanup keys outside the configured namespace" do
    Application.put_env(:fastcheck, :redis_namespace, "fastcheck:test:run-123")

    assert Namespace.ensure_scoped_keys!(["fastcheck:test:run-123:sales:hold:FC-123"]) == [
             "fastcheck:test:run-123:sales:hold:FC-123"
           ]

    assert_raise ArgumentError, fn ->
      Namespace.ensure_scoped_keys!(["sales:hold:FC-123"])
    end
  end

  test "rejects database-wide flush commands for shared Redis" do
    Application.put_env(:fastcheck, :redis_namespace, "fastcheck:test:run-123")

    for command <- ["FLUSHDB", "flushdb", "FLUSHALL", "flushall"] do
      assert_raise ArgumentError, ~r/prohibited/, fn ->
        Namespace.command([command])
      end
    end
  end

  test "test configuration provides a per-run cryptographic namespace" do
    namespace = Application.get_env(:fastcheck, :redis_namespace)

    assert is_binary(namespace)
    assert String.starts_with?(namespace, "fastcheck:test:")
  end

  test "test runtime uses the allocated Redis endpoint" do
    expected_url =
      if System.get_env("GITHUB_ACTIONS") do
        "redis://localhost:6379"
      else
        "redis://127.0.0.1:56380"
      end

    assert Application.get_env(:fastcheck, :redis_url) == expected_url
  end
end
