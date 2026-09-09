defmodule Breakaway.World.SpaceServer do
  @moduledoc """
  Authoritative simulation for one office floor.

  Clients send movement *intent* (a direction vector); this server applies it
  against the collision grid at a fixed tick and broadcasts the resulting
  positions. Nothing the browser sends is trusted as a position, so a tampered
  client cannot walk through walls or teleport into a meeting.

  It also owns zone membership: when an avatar crosses into or out of a zone the
  server emits an event, which is what drives the Discord voice moves.
  """
  use GenServer, restart: :transient

  require Logger

  alias Breakaway.World.Avatar
  alias Breakaway.Worlds
  alias Breakaway.World.Interactions
  alias Breakaway.World.Pathfinder
  alias Breakaway.Worlds.Atlas

  @tick_ms 50
  @tiles_per_second 5.4
  # Half-extents of the avatar's collision box, in tiles. Narrower than a full
  # tile so people can walk through single-tile doorways without snagging.
  @half_w 0.32
  @half_h 0.24
  # Broadcast at most this often even if nothing moved, so late joiners and
  # idle clients stay in sync.
  @keepalive_ms 1_000
  # How close counts as having arrived at a waypoint, in tiles.
  @waypoint_reached 0.12

  # --- client API -------------------------------------------------------------

  def start_link(opts) do
    space_id = Keyword.fetch!(opts, :space_id)
    GenServer.start_link(__MODULE__, opts, name: via(space_id))
  end

  def via(space_id), do: {:via, Registry, {Breakaway.World.Registry, space_id}}

  def topic(space_id), do: "space:#{space_id}"

  def join(space_id, user, pid), do: call(space_id, {:join, user, pid})
  def leave(space_id, user_id), do: call(space_id, {:leave, user_id})
  def set_input(space_id, user_id, vec), do: cast(space_id, {:input, user_id, vec})
  def walk_to(space_id, user_id, point), do: cast(space_id, {:walk_to, user_id, point})
  def set_status(space_id, user_id, text), do: call(space_id, {:status, user_id, text})
  def interact(space_id, user_id), do: call(space_id, {:interact, user_id})
  def snapshot(space_id), do: call(space_id, :snapshot)
  def zone_occupancy(space_id), do: call(space_id, :zone_occupancy)

  defp call(space_id, msg), do: GenServer.call(via(space_id), msg)
  defp cast(space_id, msg), do: GenServer.cast(via(space_id), msg)

  # --- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    space_id = Keyword.fetch!(opts, :space_id)

    with {:ok, space} <- Worlds.get_space(space_id, authorize?: false),
         {:ok, zones} <-
           Worlds.list_zones(query: [filter: [space_id: space_id]], authorize?: false),
         {:ok, props} <-
           Worlds.list_props(query: [filter: [space_id: space_id]], authorize?: false) do
      state = %{
        space: space,
        zones: zones,
        props: props,
        collision: collision_grid(space, props),
        avatars: %{},
        dirty?: false,
        last_broadcast: 0
      }

      :timer.send_interval(@tick_ms, :tick)
      {:ok, state}
    else
      error ->
        Logger.error("SpaceServer #{space_id} failed to start: #{inspect(error)}")
        {:stop, :normal}
    end
  end

  @impl true
  def handle_call({:join, user, pid}, _from, state) do
    Process.monitor(pid)

    avatar = %Avatar{
      user_id: user.id,
      name: user.display_name,
      discord_id: user.discord_id,
      palette: rem(user.avatar_palette || 0, Atlas.palette_count()),
      status: user.status_message,
      pid: pid,
      x: state.space.spawn_x + 0.5,
      y: state.space.spawn_y + 0.5
    }

    # Spawn point may be occupied; nudge to the nearest free tile.
    avatar = %{avatar | x: avatar.x, y: avatar.y} |> nudge_to_free(state)
    avatar = %{avatar | zone: zone_at(state.zones, avatar.x, avatar.y)}

    state = put_in(state.avatars[user.id], avatar)
    broadcast(state, {:joined, Avatar.to_wire(avatar)})

    if avatar.zone, do: emit_zone_change(state, avatar, nil, avatar.zone)

    {:reply, {:ok, public_state(state)}, %{state | dirty?: true}}
  end

  def handle_call({:leave, user_id}, _from, state), do: {:reply, :ok, remove(state, user_id)}

  def handle_call({:status, user_id, text}, _from, state) do
    case state.avatars[user_id] do
      nil ->
        {:reply, :ok, state}

      avatar ->
        state = put_in(state.avatars[user_id], %{avatar | status: text})
        {:reply, :ok, %{state | dirty?: true}}
    end
  end

  # Pressing E: start the nearest activity, or stop the current one.
  def handle_call({:interact, user_id}, _from, state) do
    case state.avatars[user_id] do
      nil ->
        {:reply, {:error, :not_here}, state}

      %{activity: activity} = avatar when not is_nil(activity) ->
        state = put_in(state.avatars[user_id], stand_up(avatar, state))
        {:reply, {:ok, nil}, %{state | dirty?: true}}

      avatar ->
        case nearest_interactable(state, avatar) do
          nil ->
            {:reply, {:error, :nothing_nearby}, state}

          prop ->
            next = start_activity(avatar, prop)
            state = put_in(state.avatars[user_id], next)
            {:reply, {:ok, next.activity}, %{state | dirty?: true}}
        end
    end
  end

  def handle_call(:snapshot, _from, state), do: {:reply, public_state(state), state}

  def handle_call(:zone_occupancy, _from, state), do: {:reply, occupancy(state), state}

  @impl true
  def handle_cast({:input, user_id, {dx, dy}}, state) do
    case state.avatars[user_id] do
      nil ->
        {:noreply, state}

      avatar ->
        input = {clamp(dx), clamp(dy)}
        # Touching the keys cancels wherever you had clicked.
        path = if input == {0, 0}, do: avatar.path, else: []
        {:noreply, put_in(state.avatars[user_id], %{avatar | input: input, path: path})}
    end
  end

  def handle_cast({:walk_to, user_id, {tx, ty}}, state) do
    case state.avatars[user_id] do
      nil ->
        {:noreply, state}

      avatar ->
        avatar = if avatar.seated?, do: stand_up(avatar, state), else: avatar
        path = route(state, avatar, {tx, ty})

        {:noreply,
         %{
           state
           | avatars: Map.put(state.avatars, user_id, %{avatar | path: path, input: {0, 0}}),
             dirty?: true
         }}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    {avatars, transitions, moved?} = step(state)
    state = %{state | avatars: avatars}

    Enum.each(transitions, fn {avatar, from, to} -> emit_zone_change(state, avatar, from, to) end)

    now = System.monotonic_time(:millisecond)
    stale? = now - state.last_broadcast >= @keepalive_ms

    if moved? or state.dirty? or transitions != [] or stale? do
      broadcast(state, {:tick, public_state(state)})
      {:noreply, %{state | dirty?: false, last_broadcast: now}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Enum.find(state.avatars, fn {_id, a} -> a.pid == pid end) do
      {user_id, _} -> {:noreply, remove(state, user_id)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- simulation -------------------------------------------------------------

  defp step(state) do
    dt = @tick_ms / 1000

    Enum.reduce(state.avatars, {%{}, [], false}, fn {id, avatar}, {acc, trans, moved?} ->
      next = move(avatar, dt, state)
      zone = zone_at(state.zones, next.x, next.y)

      trans = if zone != avatar.zone, do: [{next, avatar.zone, zone} | trans], else: trans
      next = %{next | zone: zone}

      moved_now? = next.x != avatar.x or next.y != avatar.y
      next = if moved_now? and next.activity, do: maybe_end_activity(state, next), else: next

      {Map.put(acc, id, next), trans, moved? or moved_now?}
    end)
  end

  defp move(avatar, dt, state) do
    cond do
      not going_anywhere?(avatar) ->
        %{avatar | moving?: false}

      # Any movement gets you out of the chair first — otherwise the avatar
      # would be standing inside the seat's own collision box.
      avatar.seated? ->
        avatar |> stand_up(state) |> move(dt, state)

      true ->
        avatar
        |> apply_step(heading(avatar), dt, state)
        |> follow_path(avatar)
    end
  end

  defp going_anywhere?(%Avatar{input: {0, 0}, path: []}), do: false
  defp going_anywhere?(_avatar), do: true

  # Held keys win; otherwise steer toward the next click-to-move waypoint.
  defp heading(%Avatar{input: {dx, dy}}) when dx != 0 or dy != 0, do: {dx * 1.0, dy * 1.0}
  defp heading(%Avatar{path: [{tx, ty} | _]} = avatar), do: {tx - avatar.x, ty - avatar.y}
  defp heading(_avatar), do: {0.0, 0.0}

  defp apply_step(avatar, {dx, dy}, dt, state) do
    # Normalise so diagonals aren't faster than the cardinals, and never
    # overshoot a waypoint that is closer than one tick's travel.
    len = :math.sqrt(dx * dx + dy * dy)

    if len < 1.0e-6 do
      %{avatar | moving?: false}
    else
      step = min(@tiles_per_second * dt, len)
      vx = dx / len * step
      vy = dy / len * step

      # Resolve each axis independently so walking into a wall at an angle
      # slides along it instead of stopping dead.
      x = slide(avatar.x, vx, avatar.y, :x, state)
      y = slide(avatar.y, vy, x, :y, state)

      travelled = abs(x - avatar.x) + abs(y - avatar.y)

      %{
        avatar
        | x: x,
          y: y,
          dir: facing(dx, dy, avatar.dir),
          moving?: travelled > 0.0001,
          distance: avatar.distance + travelled
      }
    end
  end

  defp follow_path(%Avatar{path: []} = avatar, _before), do: avatar

  defp follow_path(%Avatar{path: [{tx, ty} | rest]} = avatar, before) do
    cond do
      # Wedged against something the route did not account for — give up on the
      # path rather than shuffling into a wall forever.
      avatar.x == before.x and avatar.y == before.y ->
        %{avatar | path: [], moving?: false}

      abs(avatar.x - tx) <= @waypoint_reached and abs(avatar.y - ty) <= @waypoint_reached ->
        %{avatar | path: rest}

      true ->
        avatar
    end
  end

  # --- routing ----------------------------------------------------------------

  defp route(state, avatar, {tx, ty}) do
    from = {floor(avatar.x), floor(avatar.y)}
    to = {floor(tx), floor(ty)}

    case Pathfinder.find(from, to, &walkable_tile?(state, &1)) do
      [] ->
        []

      tiles ->
        waypoints = Enum.map(tiles, fn {x, y} -> {x + 0.5, y + 0.5} end)
        clear? = fn {x, y} -> not blocked?(state, x, y) end

        Pathfinder.smooth([{avatar.x, avatar.y} | waypoints], clear?)
    end
  end

  defp walkable_tile?(state, {x, y}) do
    x >= 0 and y >= 0 and x < state.space.width and y < state.space.height and
      not blocked?(state, x + 0.5, y + 0.5)
  end

  defp slide(value, delta, other, axis, state) do
    candidate = value + delta

    {x, y} = if axis == :x, do: {candidate, other}, else: {other, candidate}

    if blocked?(state, x, y), do: value, else: candidate
  end

  # An avatar is blocked if any corner of its box sits on a solid tile.
  defp blocked?(state, x, y) do
    Enum.any?(
      [
        {x - @half_w, y - @half_h},
        {x + @half_w, y - @half_h},
        {x - @half_w, y + @half_h},
        {x + @half_w, y + @half_h}
      ],
      fn {cx, cy} -> MapSet.member?(state.collision, {floor(cx), floor(cy)}) end
    )
  end

  defp facing(dx, dy, current) do
    cond do
      abs(dx) > abs(dy) and dx > 0 -> :right
      abs(dx) > abs(dy) and dx < 0 -> :left
      abs(dy) >= abs(dx) and dy > 0 -> :down
      abs(dy) >= abs(dx) and dy < 0 -> :up
      true -> current
    end
  end

  # Spiral outward from the spawn tile until we find somewhere to stand.
  defp nudge_to_free(avatar, state) do
    if blocked?(state, avatar.x, avatar.y) do
      Enum.find_value(1..12, avatar, fn r ->
        Enum.find_value(offsets(r), fn {ox, oy} ->
          x = avatar.x + ox
          y = avatar.y + oy
          if not blocked?(state, x, y), do: %{avatar | x: x, y: y}
        end)
      end)
    else
      avatar
    end
  end

  defp offsets(r), do: for(dx <- -r..r, dy <- -r..r, abs(dx) == r or abs(dy) == r, do: {dx, dy})

  # --- interaction ------------------------------------------------------------

  defp nearest_interactable(state, avatar) do
    state.props
    |> Enum.filter(&Interactions.interactable?(&1.kind))
    |> Enum.map(&{&1, distance_to(&1, avatar)})
    |> Enum.filter(fn {_prop, d} -> d <= Interactions.reach() end)
    |> Enum.min_by(fn {_prop, d} -> d end, fn -> nil end)
    |> case do
      {prop, _} -> prop
      nil -> nil
    end
  end

  # Sitting moves the avatar onto the furniture; everything else just labels
  # what they're doing where they stand.
  defp start_activity(avatar, prop) do
    activity = Interactions.activity(prop.kind)

    if Interactions.seat?(prop.kind) do
      %{w: w, h: h} = Atlas.prop_meta(prop.kind)

      %{
        avatar
        | activity: activity,
          seated?: true,
          dir: prop.facing,
          x: prop.x + w / 2,
          y: prop.y + h / 2,
          input: {0, 0},
          moving?: false
      }
    else
      %{avatar | activity: activity}
    end
  end

  # Seats are solid, so standing up has to put the avatar back on a free tile.
  defp stand_up(%Avatar{seated?: true} = avatar, state) do
    nudge_to_free(%{avatar | activity: nil, seated?: false}, state)
  end

  defp stand_up(avatar, _state), do: %{avatar | activity: nil}

  defp maybe_end_activity(state, avatar) do
    if nearest_interactable(state, avatar), do: avatar, else: %{avatar | activity: nil}
  end

  defp distance_to(prop, avatar) do
    %{w: w, h: h} = Atlas.prop_meta(prop.kind)
    dx = prop.x + w / 2 - avatar.x
    dy = prop.y + h / 2 - avatar.y
    :math.sqrt(dx * dx + dy * dy)
  end

  # --- zones ------------------------------------------------------------------

  defp zone_at(zones, x, y) do
    Enum.find_value(zones, fn z ->
      if x >= z.x and x < z.x + z.width and y >= z.y and y < z.y + z.height, do: z.slug
    end)
  end

  defp emit_zone_change(state, avatar, from, to) do
    event = %{
      space_id: state.space.id,
      user_id: avatar.user_id,
      discord_id: avatar.discord_id,
      name: avatar.name,
      from: from,
      to: to,
      zones: state.zones
    }

    Phoenix.PubSub.broadcast(
      Breakaway.PubSub,
      topic(state.space.id),
      {:zone_changed, Map.drop(event, [:zones])}
    )

    Breakaway.Discord.VoiceSync.handle_zone_change(event)
  end

  defp occupancy(state) do
    state.avatars
    |> Map.values()
    |> Enum.group_by(& &1.zone)
    |> Map.new(fn {zone, avatars} -> {zone, Enum.map(avatars, &Avatar.to_wire/1)} end)
  end

  # --- helpers ----------------------------------------------------------------

  defp remove(state, user_id) do
    case Map.pop(state.avatars, user_id) do
      {nil, _} ->
        state

      {avatar, avatars} ->
        state = %{state | avatars: avatars, dirty?: true}
        broadcast(state, {:left, user_id})
        if avatar.zone, do: emit_zone_change(state, avatar, avatar.zone, nil)
        state
    end
  end

  defp public_state(state) do
    %{avatars: state.avatars |> Map.values() |> Enum.map(&Avatar.to_wire/1)}
  end

  defp broadcast(state, message),
    do: Phoenix.PubSub.broadcast(Breakaway.PubSub, topic(state.space.id), message)

  defp clamp(n) when n > 0, do: 1
  defp clamp(n) when n < 0, do: -1
  defp clamp(_), do: 0

  # Solid ground tiles plus the footprints of solid props.
  defp collision_grid(space, props) do
    from_tiles =
      space.ground
      |> Enum.with_index()
      |> Enum.reduce(MapSet.new(), fn {tile_id, i}, acc ->
        if Atlas.solid?(tile_id) do
          MapSet.put(acc, {rem(i, space.width), div(i, space.width)})
        else
          acc
        end
      end)

    Enum.reduce(props, from_tiles, fn prop, acc ->
      if prop.solid do
        %{w: w, h: h} = Atlas.prop_meta(prop.kind)

        for dx <- 0..(w - 1), dy <- 0..(h - 1), reduce: acc do
          inner -> MapSet.put(inner, {prop.x + dx, prop.y + dy})
        end
      else
        acc
      end
    end)
  end
end
