defmodule FastCheck.PostgresConfigurationTest do
  use ExUnit.Case, async: false

  alias Config.Reader
  alias FastCheck.MixProject

  @dev_config Path.expand("../../config/dev.exs", __DIR__)
  @test_config Path.expand("../../config/test.exs", __DIR__)
  @perf_config Path.expand("../../config/perf.exs", __DIR__)
  @environment_keys [
    "DATABASE_URL",
    "DB_HOST",
    "DB_PORT",
    "DB_PASSWORD",
    "FASTCHECK_DEV_DB_PASSWORD",
    "FASTCHECK_TEST_DB_PASSWORD",
    "FASTCHECK_PERF_DB_PASSWORD",
    "MIGRATION_DATABASE_URL",
    "MIX_TEST_PARTITION",
    "GITHUB_ACTIONS"
  ]

  setup do
    previous_environment =
      Map.new(@environment_keys, fn key ->
        {key, System.get_env(key)}
      end)

    System.delete_env("GITHUB_ACTIONS")

    on_exit(fn -> restore_environment(previous_environment) end)
    :ok
  end

  test "development uses the allocated direct endpoint and role password from the environment" do
    System.put_env("DATABASE_URL", "ecto://wrong:wrong@127.0.0.1:5432/wrong")
    System.put_env("FASTCHECK_DEV_DB_PASSWORD", "dev-password")

    repo_config = config_for(@dev_config)

    assert repo_config[:hostname] == "127.0.0.1"
    assert repo_config[:port] == 55_432
    assert repo_config[:database] == "fastcheck_dev"
    assert repo_config[:username] == "fastcheck_dev"
    assert repo_config[:password] == "dev-password"
    refute Keyword.has_key?(repo_config, :url)
  end

  test "development requires a password from the environment" do
    System.delete_env("DATABASE_URL")
    System.delete_env("FASTCHECK_DEV_DB_PASSWORD")

    assert_raise RuntimeError, ~r/FASTCHECK_DEV_DB_PASSWORD/, fn ->
      Reader.read!(@dev_config)
    end
  end

  test "test defaults to the allocated endpoint without reading DATABASE_URL" do
    System.put_env("DATABASE_URL", "ecto://wrong:wrong@127.0.0.1:55432/fastcheck_dev")
    System.put_env("FASTCHECK_TEST_DB_PASSWORD", "test-password")
    System.delete_env("DB_HOST")
    System.delete_env("DB_PORT")
    System.delete_env("MIX_TEST_PARTITION")

    repo_config = config_for(@test_config)

    assert repo_config[:hostname] == "127.0.0.1"
    assert repo_config[:port] == 55_433
    assert repo_config[:database] == "fastcheck_test"
    assert repo_config[:username] == "fastcheck_test"
    assert repo_config[:password] == "test-password"
    refute Keyword.has_key?(repo_config, :url)
  end

  test "test preserves the existing partition suffix" do
    System.put_env("FASTCHECK_TEST_DB_PASSWORD", "test-password")
    System.put_env("MIX_TEST_PARTITION", "1")

    repo_config = config_for(@test_config)

    assert repo_config[:database] == "fastcheck_test1"
  end

  test "local test configuration cannot be redirected to a development endpoint" do
    System.put_env("FASTCHECK_TEST_DB_PASSWORD", "test-password")
    System.put_env("DB_HOST", "127.0.0.1")
    System.put_env("DB_PORT", "55432")
    System.delete_env("MIX_TEST_PARTITION")

    repo_config = config_for(@test_config)

    assert repo_config[:hostname] == "127.0.0.1"
    assert repo_config[:port] == 55_433
    assert repo_config[:database] == "fastcheck_test"
    assert repo_config[:username] == "fastcheck_test"
  end

  test "CI uses only its job-owned PostgreSQL endpoint" do
    System.put_env("GITHUB_ACTIONS", "true")
    System.put_env("FASTCHECK_TEST_DB_PASSWORD", "test-password")
    System.put_env("DB_HOST", "127.0.0.1")
    System.put_env("DB_PORT", "55432")

    repo_config = config_for(@test_config)

    assert repo_config[:hostname] == "127.0.0.1"
    assert repo_config[:port] == 5432
  end

  test "perf uses the dedicated non-superuser endpoint without reading DATABASE_URL" do
    System.put_env("DATABASE_URL", "ecto://wrong:wrong@127.0.0.1:5432/wrong")
    System.put_env("FASTCHECK_PERF_DB_PASSWORD", "perf-password")
    System.delete_env("MIGRATION_DATABASE_URL")

    repo_config = config_for(@perf_config)

    assert repo_config[:hostname] == "127.0.0.1"
    assert repo_config[:port] == 5434
    assert repo_config[:database] == "fastcheck_prod"
    assert repo_config[:username] == "fastcheck_perf"
    assert repo_config[:password] == "perf-password"
    refute Keyword.has_key?(repo_config, :url)
  end

  test "perf migrations can use the explicit perf admin URL" do
    System.put_env("FASTCHECK_PERF_DB_PASSWORD", "perf-password")
    admin_url = "ecto://postgres:admin-password@127.0.0.1:5434/fastcheck_prod"
    System.put_env("MIGRATION_DATABASE_URL", admin_url)

    repo_config = config_for(@perf_config)

    assert repo_config[:url] == admin_url
  end

  test "perf requires a password from the environment" do
    System.delete_env("FASTCHECK_PERF_DB_PASSWORD")
    System.delete_env("MIGRATION_DATABASE_URL")

    assert_raise RuntimeError, ~r/FASTCHECK_PERF_DB_PASSWORD/, fn ->
      Reader.read!(@perf_config)
    end
  end

  test "the repository requires PostgreSQL 18" do
    assert FastCheck.Repo.min_pg_version() == %Version{major: 18, minor: 0, patch: 0}
  end

  test "the active test Repo is connected to its non-superuser TEST database" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(FastCheck.Repo)

    assert {:ok, %{rows: [[database, username, superuser?]]}} =
             FastCheck.Repo.query("""
             SELECT current_database(), current_user,
               (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)
             """)

    assert String.starts_with?(database, "fastcheck_test")
    assert username == "fastcheck_test"
    refute superuser?
  end

  test "development setup migrates the pre-provisioned database without creating it" do
    aliases = MixProject.project()[:aliases]

    refute "ecto.create" in aliases[:"ecto.setup"]
    assert "ecto.migrate" in aliases[:"ecto.setup"]
    refute Keyword.has_key?(aliases, :"ecto.reset")
    assert "ecto.create --quiet" in aliases[:test]
  end

  defp config_for(path) do
    path
    |> Reader.read!()
    |> get_in([:fastcheck, FastCheck.Repo])
  end

  defp restore_environment(environment) do
    Enum.each(environment, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end
end
