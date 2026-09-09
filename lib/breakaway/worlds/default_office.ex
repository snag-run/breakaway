defmodule Breakaway.Worlds.DefaultOffice do
  @moduledoc """
  Builds the floor plan every new installation starts with.

  Kept as data-returning pure functions so the map can be rendered, diffed and
  tested without touching the database. `Breakaway.Worlds.Seeder` persists it.
  """

  alias Breakaway.Worlds.Atlas

  @width 44
  @height 32

  # Three glass-walled meeting rooms across the top — these are the rooms that
  # get bound to Discord voice channels.
  @meeting_rooms [
    %{
      slug: "aurora",
      name: "Aurora",
      x1: 1,
      y1: 1,
      x2: 13,
      y2: 10,
      floor: :carpet_teal,
      accent: "#3a7a7c",
      door: 7
    },
    %{
      slug: "basalt",
      name: "Basalt",
      x1: 15,
      y1: 1,
      x2: 28,
      y2: 10,
      floor: :carpet_plum,
      accent: "#684774",
      door: 21
    },
    %{
      slug: "summit",
      name: "Summit",
      x1: 30,
      y1: 1,
      x2: 42,
      y2: 10,
      floor: :carpet_teal,
      accent: "#3a7a7c",
      door: 36
    }
  ]

  @lounge %{slug: "lounge", name: "The Lounge", x1: 1, y1: 21, x2: 15, y2: 30}
  @kitchen %{slug: "kitchen", name: "Kitchen", x1: 17, y1: 21, x2: 28, y2: 30}
  @focus %{slug: "focus", name: "Focus Pods", x1: 30, y1: 21, x2: 42, y2: 30}

  @spawn {22, 16}

  @doc "The complete office as a plain map."
  def build do
    grid = ground_grid()

    %{
      name: "Breakaway HQ",
      slug: "hq",
      width: @width,
      height: @height,
      spawn_x: elem(@spawn, 0),
      spawn_y: elem(@spawn, 1),
      ground: flatten(grid),
      zones: zones(),
      props: props()
    }
  end

  @doc "Tile ids as a row-major list, ready for `Space.ground`."
  def flatten(grid) do
    for y <- 0..(@height - 1), x <- 0..(@width - 1) do
      grid |> Map.get({x, y}, :concrete) |> Atlas.tile_id()
    end
  end

  # --- tiles ------------------------------------------------------------------

  defp ground_grid do
    %{}
    |> fill(0, 0, @width - 1, @height - 1, :concrete)
    # the open coworking floor down the middle
    |> fill(1, 11, @width - 2, 20, :concrete)
    |> meeting_rooms()
    |> lounge()
    |> kitchen()
    |> focus_pods()
    |> outer_walls()
  end

  defp meeting_rooms(grid) do
    Enum.reduce(@meeting_rooms, grid, fn r, acc ->
      acc
      |> fill(r.x1 + 1, r.y1 + 1, r.x2 - 1, r.y2 - 1, r.floor)
      |> room_walls(r.x1, r.y1, r.x2, r.y2)
      # the wall facing the office floor is glass, so you can see who is in a call
      |> hline(r.x1, r.y2, r.x2, :glass_front)
      # ...with a doorway
      |> fill(r.door, r.y2, r.door + 1, r.y2, r.floor)
    end)
  end

  defp lounge(grid) do
    r = @lounge

    grid
    |> fill(r.x1 + 1, r.y1 + 1, r.x2 - 1, r.y2 - 1, :floor_wood)
    |> room_walls(r.x1, r.y1, r.x2, r.y2)
    |> fill(6, r.y1, 9, r.y1, :floor_wood)
  end

  defp kitchen(grid) do
    r = @kitchen

    grid
    |> fill(r.x1 + 1, r.y1 + 1, r.x2 - 1, r.y2 - 1, :kitchen_tile)
    |> room_walls(r.x1, r.y1, r.x2, r.y2)
    |> fill(21, r.y1, 24, r.y1, :kitchen_tile)
  end

  defp focus_pods(grid) do
    r = @focus

    grid
    |> fill(r.x1 + 1, r.y1 + 1, r.x2 - 1, r.y2 - 1, :floor_wood_dark)
    |> room_walls(r.x1, r.y1, r.x2, r.y2)
    |> fill(35, r.y1, 38, r.y1, :floor_wood_dark)
    # dividers between the three pods
    |> vline(34, r.y1 + 1, r.y2 - 3, :wall_front)
    |> vline(38, r.y1 + 1, r.y2 - 3, :wall_front)
  end

  # Rooms get a solid wall ring; windows punched into the outermost run.
  defp room_walls(grid, x1, y1, x2, y2) do
    grid
    |> hline(x1, y1, x2, :wall_front)
    |> hline(x1, y2, x2, :wall_front)
    |> vline(x1, y1, y2, :wall_front)
    |> vline(x2, y1, y2, :wall_front)
  end

  defp outer_walls(grid) do
    grid
    |> hline(0, 0, @width - 1, :wall_front)
    |> hline(0, @height - 1, @width - 1, :wall_front)
    |> vline(0, 0, @height - 1, :wall_front)
    |> vline(@width - 1, 0, @height - 1, :wall_front)
    |> windows_along_top([3, 4, 9, 10, 19, 20, 25, 26, 33, 34, 39, 40])
    |> windows_along_sides([5, 6, 14, 15, 24, 25, 27, 28])
  end

  defp windows_along_top(grid, xs),
    do: Enum.reduce(xs, grid, &put(&2, &1, 0, :wall_window))

  defp windows_along_sides(grid, ys) do
    Enum.reduce(ys, grid, fn y, acc ->
      acc |> put(0, y, :wall_window) |> put(@width - 1, y, :wall_window)
    end)
  end

  # --- zones ------------------------------------------------------------------

  defp zones do
    meeting =
      Enum.map(@meeting_rooms, fn r ->
        %{
          slug: r.slug,
          name: r.name,
          kind: :meeting,
          x: r.x1 + 1,
          y: r.y1 + 1,
          width: r.x2 - r.x1 - 1,
          height: r.y2 - r.y1 - 1,
          capacity: 8,
          accent: r.accent
        }
      end)

    meeting ++
      [
        %{
          slug: @lounge.slug,
          name: @lounge.name,
          kind: :social,
          x: @lounge.x1 + 1,
          y: @lounge.y1 + 1,
          width: @lounge.x2 - @lounge.x1 - 1,
          height: @lounge.y2 - @lounge.y1 - 1,
          capacity: 12,
          accent: "#d6765c"
        },
        %{
          slug: @kitchen.slug,
          name: @kitchen.name,
          kind: :social,
          x: @kitchen.x1 + 1,
          y: @kitchen.y1 + 1,
          width: @kitchen.x2 - @kitchen.x1 - 1,
          height: @kitchen.y2 - @kitchen.y1 - 1,
          capacity: 8,
          accent: "#c8a15a"
        },
        %{
          slug: @focus.slug,
          name: @focus.name,
          kind: :focus,
          x: @focus.x1 + 1,
          y: @focus.y1 + 1,
          width: @focus.x2 - @focus.x1 - 1,
          height: @focus.y2 - @focus.y1 - 1,
          capacity: 3,
          accent: "#5c6b8a"
        },
        %{
          slug: "commons",
          name: "The Commons",
          kind: :lobby,
          x: 1,
          y: 11,
          width: 42,
          height: 10,
          capacity: 40,
          accent: "#7c8896"
        }
      ]
  end

  # --- furniture --------------------------------------------------------------

  defp props do
    meeting_props() ++ desk_props() ++ lounge_props() ++ kitchen_props() ++ focus_props()
  end

  defp meeting_props do
    Enum.flat_map(@meeting_rooms, fn r ->
      cx = div(r.x1 + r.x2, 2) - 1
      cy = div(r.y1 + r.y2, 2) - 1

      [
        %{kind: :meeting_table, x: cx, y: cy},
        %{kind: :office_chair, x: cx - 1, y: cy},
        %{kind: :office_chair, x: cx - 1, y: cy + 1},
        %{kind: :office_chair, x: cx + 2, y: cy},
        %{kind: :office_chair, x: cx + 2, y: cy + 1},
        %{kind: :office_chair, x: cx, y: cy - 1},
        %{kind: :office_chair, x: cx + 1, y: cy - 1},
        %{kind: :tv_screen, x: r.x1 + 1, y: r.y1 + 1},
        %{kind: :whiteboard, x: r.x2 - 3, y: r.y1 + 1},
        %{kind: :plant_tall, x: r.x2 - 1, y: r.y2 - 1}
      ]
    end)
  end

  # Four banks of hot desks on the open floor.
  defp desk_props do
    for bank_x <- [3, 11, 27, 35], row <- [13, 17] do
      [
        %{kind: :desk, x: bank_x, y: row},
        %{kind: :office_chair, x: bank_x, y: row + 1},
        %{kind: :desk, x: bank_x + 3, y: row},
        %{kind: :office_chair, x: bank_x + 3, y: row + 1}
      ]
    end
    |> List.flatten()
    |> Kernel.++([
      %{kind: :plant_tall, x: 9, y: 12},
      %{kind: :plant_small, x: 33, y: 12},
      %{kind: :printer, x: 2, y: 19},
      %{kind: :server_rack, x: 41, y: 12},
      %{kind: :bookshelf, x: 41, y: 19},
      %{kind: :plant_tall, x: 14, y: 2},
      %{kind: :water_cooler, x: 14, y: 9},
      %{kind: :plant_tall, x: 29, y: 2},
      %{kind: :water_cooler, x: 29, y: 9}
    ])
  end

  defp lounge_props do
    [
      %{kind: :couch, x: 3, y: 24},
      %{kind: :couch, x: 3, y: 28},
      %{kind: :coffee_table, x: 6, y: 26},
      %{kind: :beanbag, x: 10, y: 24},
      %{kind: :beanbag, x: 12, y: 27},
      %{kind: :tv_screen, x: 8, y: 22},
      %{kind: :arcade, x: 13, y: 23},
      %{kind: :plant_tall, x: 2, y: 22},
      %{kind: :lamp, x: 14, y: 29},
      %{kind: :bookshelf, x: 2, y: 29}
    ]
  end

  defp kitchen_props do
    [
      %{kind: :fridge, x: 18, y: 22},
      %{kind: :coffee_machine, x: 20, y: 22},
      %{kind: :water_cooler, x: 27, y: 22},
      %{kind: :chair, x: 21, y: 27},
      %{kind: :chair, x: 24, y: 27},
      %{kind: :coffee_table, x: 22, y: 26},
      %{kind: :coffee_table, x: 23, y: 26},
      %{kind: :plant_small, x: 27, y: 29}
    ]
  end

  defp focus_props do
    [
      %{kind: :desk, x: 31, y: 23},
      %{kind: :office_chair, x: 31, y: 25},
      %{kind: :desk, x: 35, y: 23},
      %{kind: :office_chair, x: 35, y: 25},
      %{kind: :desk, x: 39, y: 23},
      %{kind: :office_chair, x: 39, y: 25},
      %{kind: :lamp, x: 33, y: 29},
      %{kind: :plant_small, x: 37, y: 29}
    ]
  end

  # --- grid helpers -----------------------------------------------------------

  defp put(grid, x, y, tile) when x >= 0 and y >= 0 and x < @width and y < @height,
    do: Map.put(grid, {x, y}, tile)

  defp put(grid, _, _, _), do: grid

  defp fill(grid, x1, y1, x2, y2, tile) do
    for x <- x1..x2, y <- y1..y2, reduce: grid do
      acc -> put(acc, x, y, tile)
    end
  end

  defp hline(grid, x1, y, x2, tile), do: fill(grid, x1, y, x2, y, tile)
  defp vline(grid, x, y1, y2, tile), do: fill(grid, x, y1, x, y2, tile)
end
