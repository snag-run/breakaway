defmodule Breakaway.Worlds.Seeder do
  @moduledoc """
  Persists the default floor plan. Safe to run repeatedly: the space and its
  zones upsert on slug, and props are replaced wholesale (they have no natural
  key, and the map is the source of truth).

  Discord channel bindings live on zones and are *not* touched by re-seeding.
  """

  alias Breakaway.Worlds
  alias Breakaway.Worlds.DefaultOffice

  def seed_default_office! do
    plan = DefaultOffice.build()

    space =
      Worlds.create_space!(
        %{
          name: plan.name,
          slug: plan.slug,
          width: plan.width,
          height: plan.height,
          spawn_x: plan.spawn_x,
          spawn_y: plan.spawn_y,
          ground: plan.ground
        },
        authorize?: false
      )

    Enum.each(plan.zones, fn zone ->
      Worlds.create_zone!(Map.put(zone, :space_id, space.id), authorize?: false)
    end)

    replace_props!(space, plan.props)

    space
  end

  defp replace_props!(space, props) do
    Worlds.list_props!(query: [filter: [space_id: space.id]], authorize?: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))

    Enum.each(props, fn prop ->
      Worlds.create_prop!(Map.put(prop, :space_id, space.id), authorize?: false)
    end)
  end
end
