defmodule Breakaway.World.Pathfinder do
  @moduledoc """
  Route an avatar across the office floor.

  A* over the tile grid with eight-way movement, followed by a string-pulling
  pass that drops waypoints the avatar can walk straight past. Without the
  smoothing pass, grid paths make people walk in visible staircases.

  The grid is small (a floor is a couple of thousand tiles), so this runs inline
  on the space's own process rather than being farmed out.
  """

  @straight 10
  # ~sqrt(2), kept integral so costs stay exact
  @diagonal 14

  @doc """
  Tiles to walk through to get from `from` to `to`, excluding `from` itself.

  `walkable?` is called with a `{x, y}` tile. Returns `[]` when the target is
  unreachable, which the caller should treat as "don't move".
  """
  def find(from, to, walkable?)

  def find(from, from, _walkable?), do: []

  def find(from, to, walkable?) do
    if walkable?.(to) do
      # The open set is ordered by {f, node}; `seen` doubles as the visited set
      # and the came-from chain.
      search(
        :gb_sets.singleton({heuristic(from, to), from}),
        %{from => 0},
        %{},
        to,
        walkable?
      )
    else
      []
    end
  end

  defp search(open, cost, came_from, goal, walkable?) do
    case :gb_sets.size(open) do
      0 ->
        []

      _ ->
        {{_f, current}, rest} = :gb_sets.take_smallest(open)

        if current == goal do
          reconstruct(came_from, goal, [])
        else
          {open, cost, came_from} =
            current
            |> neighbours(walkable?)
            |> Enum.reduce({rest, cost, came_from}, fn {next, step}, {o, c, cf} ->
              tentative = Map.fetch!(c, current) + step

              if tentative < Map.get(c, next, :infinity) do
                {
                  :gb_sets.add({tentative + heuristic(next, goal), next}, o),
                  Map.put(c, next, tentative),
                  Map.put(cf, next, current)
                }
              else
                {o, c, cf}
              end
            end)

          search(open, cost, came_from, goal, walkable?)
        end
    end
  end

  defp reconstruct(came_from, node, acc) do
    case Map.fetch(came_from, node) do
      {:ok, previous} -> reconstruct(came_from, previous, [node | acc])
      :error -> acc
    end
  end

  # Diagonals are only allowed when both adjacent cardinals are clear, so nobody
  # squeezes through the corner where two walls meet.
  defp neighbours({x, y}, walkable?) do
    cardinals = [
      {{x + 1, y}, {1, 0}},
      {{x - 1, y}, {-1, 0}},
      {{x, y + 1}, {0, 1}},
      {{x, y - 1}, {0, -1}}
    ]

    open = Map.new(cardinals, fn {tile, delta} -> {delta, walkable?.(tile)} end)

    straight =
      for {tile, delta} <- cardinals, Map.fetch!(open, delta), do: {tile, @straight}

    diagonal =
      for dx <- [-1, 1],
          dy <- [-1, 1],
          Map.fetch!(open, {dx, 0}) and Map.fetch!(open, {0, dy}),
          walkable?.({x + dx, y + dy}),
          do: {{x + dx, y + dy}, @diagonal}

    straight ++ diagonal
  end

  defp heuristic({ax, ay}, {bx, by}) do
    dx = abs(ax - bx)
    dy = abs(ay - by)
    # Octile distance — admissible for eight-way movement.
    @straight * (dx + dy) + (@diagonal - 2 * @straight) * min(dx, dy)
  end

  @doc """
  Drop waypoints the avatar can simply walk past.

  `clear?` is called with a world position and must say whether the avatar's
  body fits there. Points are world coordinates, not tiles.
  """
  def smooth([], _clear?), do: []
  def smooth([_only] = points, _clear?), do: points

  def smooth([first | _] = points, clear?) do
    do_smooth(first, tl(points), clear?, [])
  end

  defp do_smooth(_anchor, [], _clear?, acc), do: Enum.reverse(acc)

  defp do_smooth(anchor, remaining, clear?, acc) do
    # Take the furthest point still reachable in a straight line from the anchor.
    {kept, rest} = furthest_visible(anchor, remaining, clear?)
    do_smooth(kept, rest, clear?, [kept | acc])
  end

  defp furthest_visible(anchor, [next | rest], clear?) do
    case Enum.split_while(rest, &walkable_line?(anchor, &1, clear?)) do
      {[], _} -> {next, rest}
      {visible, remainder} -> {List.last(visible), remainder}
    end
  end

  # Sample along the segment; the avatar is a box, so a tile-level check is not
  # enough on its own.
  defp walkable_line?({ax, ay}, {bx, by}, clear?) do
    distance = :math.sqrt(:math.pow(bx - ax, 2) + :math.pow(by - ay, 2))
    steps = max(2, ceil(distance * 6))

    Enum.all?(0..steps, fn i ->
      t = i / steps
      clear?.({ax + (bx - ax) * t, ay + (by - ay) * t})
    end)
  end
end
