defmodule Breakaway.World.PathfinderTest do
  use ExUnit.Case, async: true

  alias Breakaway.World.Pathfinder

  # A 7x5 floor with a wall down the middle, open at the top and bottom:
  #
  #   0123456
  # 0 .......
  # 1 ...#...
  # 2 ...#...
  # 3 ...#...
  # 4 .......
  @wall MapSet.new([{3, 1}, {3, 2}, {3, 3}])

  defp walkable?({x, y}),
    do: x >= 0 and y >= 0 and x <= 6 and y <= 4 and not MapSet.member?(@wall, {x, y})

  test "no path is needed to stand still" do
    assert Pathfinder.find({1, 1}, {1, 1}, &walkable?/1) == []
  end

  test "an open floor is crossed directly" do
    path = Pathfinder.find({0, 0}, {3, 0}, &walkable?/1)

    assert List.last(path) == {3, 0}
    assert length(path) == 3
  end

  test "a wall is routed around, not through" do
    path = Pathfinder.find({0, 2}, {6, 2}, &walkable?/1)

    assert List.last(path) == {6, 2}
    assert Enum.all?(path, &walkable?/1)
    refute Enum.any?(path, &MapSet.member?(@wall, &1))

    # The wall spans rows 1-3 at x = 3, so the route has to leave row 2 and slip
    # past through the gap at the top or the bottom.
    assert Enum.any?(path, fn {x, y} -> x == 3 and y in [0, 4] end),
           "expected the path to go around the wall, got #{inspect(path)}"
  end

  test "each step is adjacent to the last" do
    path = Pathfinder.find({0, 4}, {6, 0}, &walkable?/1)

    Enum.zip([{0, 4} | path], path)
    |> Enum.each(fn {{ax, ay}, {bx, by}} ->
      assert abs(ax - bx) <= 1 and abs(ay - by) <= 1
      refute {ax, ay} == {bx, by}
    end)
  end

  test "an unreachable target yields no path" do
    sealed = MapSet.new([{1, 0}, {1, 1}, {1, 2}, {0, 2}])

    walkable = fn {x, y} = t ->
      x >= 0 and y >= 0 and x <= 6 and y <= 4 and not MapSet.member?(sealed, t)
    end

    assert Pathfinder.find({3, 3}, {0, 0}, walkable) == []
  end

  test "a target inside a wall yields no path" do
    assert Pathfinder.find({0, 2}, {3, 2}, &walkable?/1) == []
  end

  test "diagonals do not cut through the corner between two walls" do
    blocked = MapSet.new([{1, 0}, {0, 1}])
    walkable = fn t -> not MapSet.member?(blocked, t) end

    # (0,0) and (1,1) touch only at a corner that is walled on both sides.
    path = Pathfinder.find({0, 0}, {1, 1}, walkable)

    refute path == [{1, 1}], "squeezed diagonally between two walls"
  end

  describe "smoothing" do
    test "a straight run collapses to its endpoint" do
      points = [{0.5, 0.5}, {1.5, 0.5}, {2.5, 0.5}, {3.5, 0.5}]

      assert Pathfinder.smooth(points, fn _ -> true end) == [{3.5, 0.5}]
    end

    test "a corner is kept when the direct line is blocked" do
      # Anything with x > 1.0 and y < 1.0 is wall, so the route must turn.
      clear? = fn {x, y} -> not (x > 1.0 and y < 1.0) end
      points = [{0.5, 0.5}, {0.5, 1.5}, {1.5, 1.5}, {2.5, 1.5}]

      smoothed = Pathfinder.smooth(points, clear?)

      assert List.last(smoothed) == {2.5, 1.5}
      assert length(smoothed) >= 2, "the turn was smoothed away through a wall"
    end

    test "trivial inputs are returned untouched" do
      assert Pathfinder.smooth([], fn _ -> true end) == []
      assert Pathfinder.smooth([{1.0, 1.0}], fn _ -> true end) == [{1.0, 1.0}]
    end
  end
end
