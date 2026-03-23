defmodule FastCheck.ReleaseTest do
  use ExUnit.Case, async: true

  alias FastCheck.Release

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
end
