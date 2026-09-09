defmodule Mix.Tasks.Breakaway.Seed do
  @shortdoc "Seeds the default office floor plan"
  @moduledoc """
  Creates (or refreshes) the default office.

      mix breakaway.seed

  Re-running updates the map and furniture while leaving any Discord channel
  bindings on the zones intact.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    space = Breakaway.Worlds.Seeder.seed_default_office!()

    zones = Breakaway.Worlds.list_zones!(query: [filter: [space_id: space.id]], authorize?: false)
    props = Breakaway.Worlds.list_props!(query: [filter: [space_id: space.id]], authorize?: false)

    Mix.shell().info("""
    Seeded #{space.name} (/#{space.slug})
      #{space.width}x#{space.height} tiles, spawn at #{space.spawn_x},#{space.spawn_y}
      #{length(zones)} zones, #{length(props)} props
    """)
  end
end
