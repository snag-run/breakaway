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

  test "desk chairs face into their desk, not away from it", %{plan: plan} do
    chairs = Enum.filter(plan.props, &(&1.kind == :office_chair))
    desks = MapSet.new(plan.props, fn p -> {p.kind, p.x, p.y} end)

    # Every chair sitting directly below a desk must face up into it.
    at_a_desk =
      Enum.filter(chairs, fn c ->
        MapSet.member?(desks, {:desk, c.x, c.y - 1})
      end)

    assert at_a_desk != [], "expected some chairs to be paired with desks"

    for chair <- at_a_desk do
      assert Map.get(chair, :facing) == :up,
             "chair at #{chair.x},#{chair.y} sits below a desk but faces #{inspect(Map.get(chair, :facing))}"
    end
  end

  test "meeting room chairs above the table still face it", %{plan: plan} do
    tables = MapSet.new(plan.props, fn p -> {p.kind, p.x, p.y} end)

    above_a_table =
      Enum.filter(plan.props, fn p ->
        p.kind == :office_chair and
          Enum.any?(0..1, &MapSet.member?(tables, {:meeting_table, p.x - &1, p.y + 1}))
      end)

    assert above_a_table != []

    for chair <- above_a_table do
      assert Map.get(chair, :facing, :down) == :down
    end
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
