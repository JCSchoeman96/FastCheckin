defmodule FastCheck.Release do
  @moduledoc """
  Release tasks for running Ecto migrations in production without Mix.

  Usage (Railway deploy command or one-off task):

      bin/fastcheck eval "FastCheck.Release.migrate()"

  """

  @app :fastcheck

  def migrate do
    load_app()

    for repo <- repos() do
      with_migration_database_url(repo, fn ->
        {:ok, _, _} =
          Ecto.Migrator.with_repo(repo, fn repo ->
            Ecto.Migrator.run(repo, :up, all: true)
          end)
      end)
    end
  end

  def rollback(repo, version) do
    load_app()

    with_migration_database_url(repo, fn ->
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    end)
  end

  def migration_repo_config(repo_config, migration_database_url)

  def migration_repo_config(repo_config, nil), do: repo_config
  def migration_repo_config(repo_config, ""), do: repo_config

  def migration_repo_config(repo_config, migration_database_url) do
    Keyword.put(repo_config, :url, migration_database_url)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end

  defp with_migration_database_url(repo, fun) do
    repo_config = Application.get_env(@app, repo, [])
    updated_config = migration_repo_config(repo_config, System.get_env("MIGRATION_DATABASE_URL"))

    Application.put_env(@app, repo, updated_config)

    try do
      fun.()
    after
      Application.put_env(@app, repo, repo_config)
    end
  end
end
