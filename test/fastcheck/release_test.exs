defmodule FastCheck.ReleaseTest do
  use ExUnit.Case, async: true

  alias FastCheck.Release

  test "FastCheck.Repo uses a PostgreSQL advisory lock for migrations" do
    repo_config = Application.fetch_env!(:fastcheck, FastCheck.Repo)

    assert Keyword.get(repo_config, :migration_lock) == :pg_advisory_lock
  end

  test "migration_repo_config overrides the repo url when a migration url is provided" do
    repo_config = [url: "ecto://app:secret@pgbouncer:5432/fastcheck_prod", pool_size: 20]

    assert Release.migration_repo_config(
             repo_config,
             "ecto://app:secret@postgres:5432/fastcheck_prod"
           ) ==
             [url: "ecto://app:secret@postgres:5432/fastcheck_prod", pool_size: 20]
  end

  test "migration_repo_config leaves the repo config unchanged without an override" do
    repo_config = [url: "ecto://app:secret@pgbouncer:5432/fastcheck_prod", pool_size: 20]

    assert Release.migration_repo_config(repo_config, nil) == repo_config
    assert Release.migration_repo_config(repo_config, "") == repo_config
  end

  test "PgBouncer modes require a direct migration URL" do
    repo_config = [url: "ecto://app:secret@pgbouncer:5432/fastcheck_prod"]

    message =
      "MIGRATION_DATABASE_URL must point directly to PostgreSQL when DATABASE_POOLING_MODE uses PgBouncer."

    for mode <- [:pgbouncer_transaction, :pgbouncer_session] do
      for migration_url <- [nil, "", "   "] do
        assert_raise ArgumentError, message, fn ->
          Release.migration_repo_config(repo_config, migration_url, mode)
        end
      end
    end
  end

  test "direct mode keeps the application URL when no migration URL is set" do
    repo_config = [url: "ecto://app:secret@postgres:5432/fastcheck_prod", pool_size: 20]

    assert Release.migration_repo_config(repo_config, nil, :direct) == repo_config
    assert Release.migration_repo_config(repo_config, "   ", :direct) == repo_config
  end

  test "a direct migration URL overrides only the repo URL" do
    repo_config = [
      url: "ecto://app:secret@pgbouncer:5432/fastcheck_prod",
      pool_size: 20,
      migration_lock: :pg_advisory_lock
    ]

    assert Release.migration_repo_config(
             repo_config,
             " ecto://admin:secret@postgres:5432/fastcheck_prod ",
             :pgbouncer_transaction
           ) ==
             Keyword.put(
               repo_config,
               :url,
               "ecto://admin:secret@postgres:5432/fastcheck_prod"
             )
  end
end
