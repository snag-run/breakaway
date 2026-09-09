defmodule Breakaway.Worlds.DefaultOfficeTest do
  use ExUnit.Case, async: true

  alias Breakaway.Worlds.{Atlas, DefaultOffice}

  setup_all do
    plan = DefaultOffice.build()
    tile_at = fn x, y -> Enum.at(plan.ground, y * plan.width + x) end
    %{plan: plan, tile_at: tile_at}
  end

  test "the tile array matches the declared dimensions", %{plan: plan} do
    assert length(plan.ground) == plan.width * plan.height
    assert Enum.all?(plan.ground, &is_integer/1)
  end

  test "the floor is sealed by a solid border", %{plan: plan, tile_at: tile_at} do
    edges =
      Enum.map(0..(plan.width - 1), &{&1, 0}) ++
        Enum.map(0..(plan.width - 1), &{&1, plan.height - 1}) ++
        Enum.map(0..(plan.height - 1), &{0, &1}) ++
        Enum.map(0..(plan.height - 1), &{plan.width - 1, &1})

    for {x, y} <- edges do
      assert Atlas.solid?(tile_at.(x, y)), "hole in the outer wall at #{x},#{y}"
    end
  end

  test "spawn is on a walkable tile", %{plan: plan, tile_at: tile_at} do
    refute Atlas.solid?(tile_at.(plan.spawn_x, plan.spawn_y))
  end

  test "zones sit inside the floor", %{plan: plan} do
    for zone <- plan.zones do
      assert zone.x >= 0 and zone.y >= 0
      assert zone.x + zone.width <= plan.width
      assert zone.y + zone.height <= plan.height
      assert zone.width > 0 and zone.height > 0
    end
  end

  test "zone slugs are unique", %{plan: plan} do
    slugs = Enum.map(plan.zones, & &1.slug)
    assert length(slugs) == length(Enum.uniq(slugs))
  end

  test "there are meeting rooms to bind to Discord", %{plan: plan} do
    meetings = Enum.filter(plan.zones, &(&1.kind == :meeting))
    assert length(meetings) >= 3
  end

  test "props are known kinds placed inside the floor", %{plan: plan} do
    known = MapSet.new(Atlas.prop_names())

    for prop <- plan.props do
      assert MapSet.member?(known, prop.kind), "unknown prop #{prop.kind}"
      %{w: w, h: h} = Atlas.prop_meta(prop.kind)
      assert prop.x >= 0 and prop.y >= 0
      assert prop.x + w <= plan.width
      assert prop.y + h <= plan.height
    end
  end

  test "every meeting room can actually be walked into", %{plan: plan, tile_at: tile_at} do
    walkable = fn {x, y} ->
      x >= 0 and y >= 0 and x < plan.width and y < plan.height and
        not Atlas.solid?(tile_at.(x, y))
    end

    reachable = flood_fill({plan.spawn_x, plan.spawn_y}, walkable)

    for zone <- Enum.filter(plan.zones, &(&1.kind in [:meeting, :social, :focus])) do
      tiles =
        for x <- zone.x..(zone.x + zone.width - 1),
            y <- zone.y..(zone.y + zone.height - 1),
            do: {x, y}

      assert Enum.any?(tiles, &MapSet.member?(reachable, &1)),
             "#{zone.slug} is walled off from spawn"
    end
  end

  defp flood_fill(start, walkable) do
    do_fill([start], MapSet.new([start]), walkable)
  end

  defp do_fill([], seen, _walkable), do: seen

  defp do_fill([{x, y} | rest], seen, walkable) do
    next =
      [{x + 1, y}, {x - 1, y}, {x, y + 1}, {x, y - 1}]
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.filter(walkable)

    do_fill(rest ++ next, Enum.into(next, seen), walkable)
  end
end
