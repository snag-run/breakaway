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
  @default_away_after_ms :timer.minutes(5)

  # --- client API -------------------------------------------------------------

  def start_link(opts) do
    space_id = Keyword.fetch!(opts, :space_id)
    GenServer.start_link(__MODULE__, opts, name: via(space_id))
  end

  @doc """
  Cluster-wide name for a floor's simulation.

  Registered through `:global` rather than a local `Registry`, so a floor has
  exactly one simulation across the whole cluster. Two nodes racing to start the
  same floor is fine: the loser gets `{:error, {:already_started, pid}}` and uses
  the winner's process. Calls and casts route across nodes transparently.
  """
  def via(space_id), do: {:global, global_name(space_id)}

  def global_name(space_id), do: {:breakaway_space, space_id}

  @doc "Whereabouts of a floor's simulation, anywhere in the cluster."
  def whereis(space_id) do
    case :global.whereis_name(global_name(space_id)) do
      :undefined -> nil
      pid -> pid
    end
  end

  def topic(space_id), do: "space:#{space_id}"

  def join(space_id, user, pid), do: call(space_id, {:join, user, pid})
  def leave(space_id, user_id), do: call(space_id, {:leave, user_id})
  def set_input(space_id, user_id, vec), do: cast(space_id, {:input, user_id, vec})
  def walk_to(space_id, user_id, point), do: cast(space_id, {:walk_to, user_id, point})
  def refresh_profile(space_id, user), do: call(space_id, {:profile, user})
  def mark_active(space_id, user_id), do: cast(space_id, {:active, user_id})
  def voice_targets(space_id), do: call(space_id, :voice_targets)
  def apply_voice_states(space_id, states), do: cast(space_id, {:voice_states, states})
  def interact(space_id, user_id), do: call(space_id, {:interact, user_id})
  def snapshot(space_id), do: call(space_id, :snapshot)
  def zone_occupancy(space_id), do: call(space_id, :zone_occupancy)

  defp call(space_id, msg), do: GenServer.call(via(space_id), msg)
  defp cast(space_id, msg), do: GenServer.cast(via(space_id), msg)

  # --- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    space_id = Keyword.fetch!(opts, :space_id)

    # A second, node-local registration. `:global` gives cluster-wide
    # uniqueness but no cheap way to list "the floors running here", which is
    # what the voice poller iterates.
    {:ok, _} = Registry.register(Breakaway.World.Registry, space_id, nil)

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
      active_at: now_ms()
    }

    {x, y} = spawn_position(state, user)
    avatar = %{avatar | x: x, y: y}

    # Spawn point may be occupied; nudge to the nearest free tile.
    avatar = %{avatar | x: avatar.x, y: avatar.y} |> nudge_to_free(state)
    avatar = %{avatar | zone: zone_at(state.zones, avatar.x, avatar.y)}

    state = put_in(state.avatars[user.id], avatar)
    broadcast(state, {:joined, Avatar.to_wire(avatar)})

    if avatar.zone, do: emit_zone_change(state, avatar, nil, avatar.zone)

    {:reply, {:ok, public_state(state)}, %{state | dirty?: true}}
  end

  def handle_call({:leave, user_id}, _from, state), do: {:reply, :ok, remove(state, user_id)}

  # Someone edited their profile — show the change to everyone without making
  # them walk out and back in.
  def handle_call({:profile, user}, _from, state) do
    case state.avatars[user.id] do
      nil ->
        {:reply, :ok, state}

      avatar ->
        updated = %{
          avatar
          | name: user.display_name,
            status: user.status_message,
            palette: rem(user.avatar_palette || 0, Atlas.palette_count())
        }

        {:reply, :ok, %{state | avatars: Map.put(state.avatars, user.id, updated), dirty?: true}}
    end
  end

  # Pressing E: start the nearest activity, or stop the current one.
  def handle_call({:interact, user_id}, _from, state) do
    case state.avatars[user_id] do
      nil ->
        {:reply, {:error, :not_here}, state}

      %{activity: activity} = avatar when not is_nil(activity) ->
        state = put_in(state.avatars[user_id], avatar |> touch() |> stand_up(state))
        {:reply, {:ok, nil}, %{state | dirty?: true}}

      avatar ->
        case nearest_interactable(state, avatar) do
          nil ->
            {:reply, {:error, :nothing_nearby}, state}

          prop ->
            next = avatar |> touch() |> start_activity(prop)
            state = put_in(state.avatars[user_id], next)
            {:reply, {:ok, next.activity}, %{state | dirty?: true}}
        end
    end
  end

  def handle_call(:snapshot, _from, state), do: {:reply, public_state(state), state}

  def handle_call(:zone_occupancy, _from, state), do: {:reply, occupancy(state), state}

  # Who to ask Discord about: everyone on this floor, provided we know which
  # guild to ask in.
  def handle_call(:voice_targets, _from, state) do
    targets =
      case primary_guild(state) do
        nil ->
          []

        guild_id ->
          state.avatars
          |> Map.values()
          |> Enum.reject(&is_nil(&1.discord_id))
          |> Enum.map(&%{user_id: &1.user_id, discord_id: &1.discord_id, guild_id: guild_id})
      end

    {:reply, targets, state}
  end

  @impl true
  def handle_cast({:input, user_id, {dx, dy}}, state) do
    case state.avatars[user_id] do
      nil ->
        {:noreply, state}

      avatar ->
        input = {clamp(dx), clamp(dy)}
        # Touching the keys cancels wherever you had clicked.
        path = if input == {0, 0}, do: avatar.path, else: []
        avatar = %{avatar | input: input, path: path}
        avatar = if input == {0, 0}, do: avatar, else: touch(avatar)
        {:noreply, put_in(state.avatars[user_id], avatar)}
    end
  end

  def handle_cast({:active, user_id}, state) do
    case state.avatars[user_id] do
      nil -> {:noreply, state}
      %{away?: false} = avatar -> {:noreply, put_in(state.avatars[user_id], touch(avatar))}
      avatar -> {:noreply, %{put_in(state.avatars[user_id], touch(avatar)) | dirty?: true}}
    end
  end

  # What Discord says about who is really in a call.
  def handle_cast({:voice_states, states}, state) do
    {avatars, changed?} =
      Enum.reduce(states, {state.avatars, false}, fn {user_id, connection}, {acc, changed?} ->
        case Map.fetch(acc, user_id) do
          :error ->
            {acc, changed?}

          {:ok, avatar} ->
            channel_id = connection && connection.channel_id
            muted? = !!(connection && connection.muted?)

            updated = %{avatar | voice_channel_id: channel_id, muted?: muted?}

            {Map.put(acc, user_id, updated),
             changed? or avatar.voice_channel_id != channel_id or avatar.muted? != muted?}
        end
      end)

    state = %{state | avatars: avatars}
    state = Enum.reduce(Map.keys(states), state, &walk_to_their_call/2)

    {:noreply, %{state | dirty?: state.dirty? or changed?}}
  end

  def handle_cast({:walk_to, user_id, {tx, ty}}, state) do
    case state.avatars[user_id] do
      nil ->
        {:noreply, state}

      avatar ->
        avatar = if avatar.seated?, do: stand_up(avatar, state), else: avatar
        avatar = touch(avatar)
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
    now = now_ms()

    Enum.reduce(state.avatars, {%{}, [], false}, fn {id, avatar}, {acc, trans, changed?} ->
      next = move(avatar, dt, state)
      zone = zone_at(state.zones, next.x, next.y)

      trans = if zone != avatar.zone, do: [{next, avatar.zone, zone} | trans], else: trans
      next = %{next | zone: zone}

      moved_now? = next.x != avatar.x or next.y != avatar.y
      next = if moved_now? and next.activity, do: maybe_end_activity(state, next), else: next
      next = if moved_now?, do: touch(next), else: idle_check(next, now)

      {Map.put(acc, id, next), trans, changed? or moved_now? or next.away? != avatar.away?}
    end)
  end

  defp touch(avatar), do: %{avatar | active_at: now_ms(), away?: false}

  defp idle_check(%Avatar{active_at: nil} = avatar, _now), do: avatar

  defp idle_check(avatar, now),
    do: %{avatar | away?: now - avatar.active_at >= away_after_ms()}

  defp away_after_ms,
    do: Application.get_env(:breakaway, :away_after_ms, @default_away_after_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Come back to where you left off, as long as it is still on this floor.
  # `nudge_to_free/2` sorts out a spot that has since been furnished.
  defp spawn_position(state, user) do
    space_id = state.space.id

    with ^space_id <- Map.get(user, :last_space_id),
         x when is_number(x) <- Map.get(user, :last_x),
         y when is_number(y) <- Map.get(user, :last_y),
         true <- x >= 0 and y >= 0 and x < state.space.width and y < state.space.height do
      {x * 1.0, y * 1.0}
    else
      _ -> {state.space.spawn_x + 0.5, state.space.spawn_y + 0.5}
    end
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

  # Someone who joined a call from Discord should show up in that room, so the
  # floor matches the conversation. They walk in rather than teleporting.
  defp walk_to_their_call(user_id, state) do
    with %Avatar{voice_channel_id: channel_id} = avatar when is_binary(channel_id) <-
           state.avatars[user_id],
         %{slug: slug} = zone <- zone_for_channel(state, channel_id),
         true <- avatar.zone != slug,
         # Don't fight someone who is already on their way somewhere.
         [] <- avatar.path,
         {:ok, spot} <- free_spot_in_zone(state, zone) do
      put_in(state.avatars[user_id], %{avatar | path: route(state, avatar, spot)})
    else
      _ -> state
    end
  end

  defp zone_for_channel(state, channel_id),
    do: Enum.find(state.zones, &(&1.discord_channel_id == channel_id))

  # Meeting rooms have a table in the middle, so look outward from the centre
  # for somewhere to actually stand.
  defp free_spot_in_zone(state, zone) do
    cx = zone.x + zone.width / 2
    cy = zone.y + zone.height / 2

    for(
      x <- zone.x..(zone.x + zone.width - 1),
      y <- zone.y..(zone.y + zone.height - 1),
      do: {x, y}
    )
    |> Enum.sort_by(fn {x, y} -> :math.pow(x + 0.5 - cx, 2) + :math.pow(y + 0.5 - cy, 2) end)
    |> Enum.find_value(:error, fn {x, y} ->
      if not blocked?(state, x + 0.5, y + 0.5), do: {:ok, {x + 0.5, y + 0.5}}
    end)
  end

  defp primary_guild(state), do: Enum.find_value(state.zones, & &1.discord_guild_id)

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
      voice_channel_id: avatar.voice_channel_id,
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
        remember_position(state, avatar)
        state = %{state | avatars: avatars, dirty?: true}
        broadcast(state, {:left, user_id})
        if avatar.zone, do: emit_zone_change(state, avatar, avatar.zone, nil)
        state
    end
  end

  # Done inline rather than on a task: people leave rarely, it is one indexed
  # update, and a failure here must never take the floor down with it.
  defp remember_position(state, avatar) do
    with {:ok, user} <- Ash.get(Breakaway.Accounts.User, avatar.user_id, authorize?: false) do
      Breakaway.Accounts.remember_position(
        user,
        %{last_space_id: state.space.id, last_x: avatar.x, last_y: avatar.y},
        authorize?: false
      )
    end
  rescue
    error ->
      Logger.warning("could not remember position for #{avatar.user_id}: #{inspect(error)}")
      :ok
  catch
    # A database that is down or a checked-in sandbox connection exits rather
    # than raising; either way, losing a saved position must not take the floor
    # down with it.
    :exit, reason ->
      Logger.warning("could not remember position for #{avatar.user_id}: #{inspect(reason)}")
      :ok
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
