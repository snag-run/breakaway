defmodule Breakaway.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :breakaway

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Creates or refreshes the default office.

  Idempotent by design — it updates the map and furniture and leaves the Discord
  channel bindings on the zones alone — so it is safe in a release command that
  runs on every deploy. Without it a fresh database has no floor to walk on and
  `/office` has nothing to render.
  """
  def seed do
    load_app()
    {:ok, _} = Application.ensure_all_started(@app)
    Breakaway.Worlds.Seeder.seed_default_office!()
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
