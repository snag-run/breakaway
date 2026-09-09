defmodule Breakaway.Fixtures do
  @moduledoc "Builders for the entities tests need."

  alias Breakaway.Worlds
  alias Breakaway.Worlds.Atlas

  def user_fixture(handle \\ nil) do
    handle = handle || "user#{System.unique_integer([:positive])}"

    Ash.create!(
      Breakaway.Accounts.User,
      %{handle: handle, display_name: String.capitalize(handle), avatar_palette: 0},
      action: :register_dev_user,
      authorize?: false
    )
  end

  @doc """
  A 10x10 room: solid wall border, open concrete inside, and a 3x3 zone in the
  top-left corner reached through a gap in its wall.

      0123456789
    0 ##########
    1 #........#
    2 #.###....#
    3 #.#Z#....#     Z = inside "cell" zone
    4 #.#.#....#     the zone's wall has a gap at (3,5)
    5 #.#.#....#
    6 #.###....#
    7 #........#
    8 #........#
    9 ##########
  """
  def small_space_fixture(attrs \\ %{}) do
    wall = Atlas.tile_id(:wall_front)
    floor = Atlas.tile_id(:concrete)

    solid =
      MapSet.new([
        {2, 2}, {3, 2}, {4, 2},
        {2, 3}, {4, 3},
        {2, 4}, {4, 4},
        {2, 5}, {4, 5},
        {2, 6}, {3, 6}, {4, 6}
      ])

    ground =
      for y <- 0..9, x <- 0..9 do
        cond do
          x == 0 or y == 0 or x == 9 or y == 9 -> wall
          MapSet.member?(solid, {x, y}) -> wall
          true -> floor
        end
      end

    space =
      Worlds.create_space!(
        Map.merge(
          %{
            name: "Test Floor",
            slug: "test-#{System.unique_integer([:positive])}",
            width: 10,
            height: 10,
            spawn_x: 6,
            spawn_y: 4,
            ground: ground
          },
          attrs
        ),
        authorize?: false
      )

    Worlds.create_zone!(
      %{
        space_id: space.id,
        name: "The Cell",
        slug: "cell",
        kind: :meeting,
        x: 3,
        y: 3,
        width: 1,
        height: 3,
        accent: "#ffffff"
      },
      authorize?: false
    )

    space
  end

  @doc "Binds a zone to a fake Discord voice channel."
  def bind_zone!(space, slug, opts \\ []) do
    zone =
      Worlds.list_zones!(query: [filter: [space_id: space.id, slug: slug]], authorize?: false)
      |> hd()

    Worlds.bind_discord_channel!(
      zone,
      %{
        discord_guild_id: opts[:guild_id] || "guild-1",
        discord_channel_id: opts[:channel_id] || "channel-1",
        discord_channel_name: opts[:channel_name] || "aurora-voice",
        auto_move: Keyword.get(opts, :auto_move, true)
      },
      authorize?: false
    )
  end
end
