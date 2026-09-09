defmodule Breakaway.World.Avatar do
  @moduledoc """
  One person's presence on the floor.

  Position is in tile units and may be fractional; `x`/`y` is the point between
  the character's feet, which is also what the renderer sorts by for depth.
  """

  @enforce_keys [:user_id, :name, :discord_id]
  defstruct [
    :user_id,
    :name,
    :discord_id,
    :status,
    :activity,
    :pid,
    x: 0.0,
    y: 0.0,
    dir: :down,
    palette: 0,
    input: {0, 0},
    # Remaining click-to-move waypoints, in world coordinates.
    path: [],
    moving?: false,
    seated?: false,
    # distance walked, in tiles — the renderer derives the walk frame from it so
    # the animation stays in step with actual movement rather than wall time
    distance: 0.0,
    zone: nil
  ]

  @type t :: %__MODULE__{}

  @doc "The wire form sent to the browser each tick — deliberately small."
  def to_wire(%__MODULE__{} = a) do
    %{
      id: a.user_id,
      n: a.name,
      x: Float.round(a.x, 3),
      y: Float.round(a.y, 3),
      d: a.dir,
      p: a.palette,
      m: a.moving?,
      f: a.distance |> Kernel.*(2.4) |> trunc() |> rem(4),
      z: a.zone,
      s: a.activity || a.status,
      a: a.activity,
      sit: a.seated?
    }
  end
end
