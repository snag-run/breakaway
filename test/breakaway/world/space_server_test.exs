defmodule Breakaway.World.SpaceServerTest do
  @moduledoc """
  Behaviour of the authoritative simulation. These drive real time (the server
  ticks on a timer), so they walk for a fixed duration and assert on the result
  rather than on exact positions.
  """
  use Breakaway.DataCase

  import Breakaway.Fixtures

  alias Breakaway.World

  @tiles_per_second 5.4

  setup do
    space = small_space_fixture()
    on_exit(fn -> stop_space(space.id) end)
    %{space: space, user: user_fixture()}
  end

  defp stop_space(space_id) do
    case Registry.lookup(Breakaway.World.Registry, space_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Breakaway.World.SpaceSupervisor, pid)
      [] -> :ok
    end
  end

  defp walk(space, user, vec, ms) do
    World.move(space.id, user.id, vec)
    Process.sleep(ms)
    World.move(space.id, user.id, {0, 0})
    Process.sleep(120)
    me(space, user)
  end

  defp me(space, user) do
    World.snapshot(space.id).avatars |> Enum.find(&(&1.id == user.id))
  end

  test "joining places the avatar on the spawn tile", %{space: space, user: user} do
    assert {:ok, state} = World.join(space.id, user)
    assert [avatar] = state.avatars
    assert avatar.id == user.id
    assert avatar.n == user.display_name
    assert_in_delta avatar.x, space.spawn_x + 0.5, 0.01
    assert_in_delta avatar.y, space.spawn_y + 0.5, 0.01
  end

  test "walking moves at the expected speed", %{space: space, user: user} do
    {:ok, _} = World.join(space.id, user)
    before = me(space, user)

    after_walk = walk(space, user, {0, -1}, 400)

    travelled = before.y - after_walk.y
    assert_in_delta travelled, @tiles_per_second * 0.4, 0.6
    assert after_walk.d == :up
  end

  test "a wall stops the avatar", %{space: space, user: user} do
    {:ok, _} = World.join(space.id, user)

    # Spawn is at 5,7; the south wall is y = 9. Walk into it for well longer
    # than it takes to reach.
    avatar = walk(space, user, {0, 1}, 1200)

    assert avatar.y < 9.0, "walked into the wall"
    assert avatar.y > 8.0, "should have reached the wall"
  end

  test "walking through the gap enters the zone and announces it", %{space: space, user: user} do
    World.subscribe(space.id)
    {:ok, _} = World.join(space.id, user)

    assert me(space, user).z == nil

    walk(space, user, {0, -1}, 400)
    avatar = walk(space, user, {-1, 0}, 500)

    assert avatar.z == "cell", "expected to be in the cell, ended at #{avatar.x},#{avatar.y}"
    assert_receive {:zone_changed, %{to: "cell", from: nil}}, 500
  end

  test "the sealed side of the room cannot be entered", %{space: space, user: user} do
    {:ok, _} = World.join(space.id, user)

    # Line up with the middle of the cell (y = 4) where the wall is solid.
    walk(space, user, {0, -1}, 700)
    avatar = walk(space, user, {-1, 0}, 800)

    assert avatar.z == nil
    assert avatar.x > 4.0, "should have been stopped by the cell wall"
  end

  test "diagonal movement is not faster than cardinal", %{space: space, user: user} do
    {:ok, _} = World.join(space.id, user)
    start = me(space, user)
    straight = walk(space, user, {-1, 0}, 200)
    straight_distance = abs(start.x - straight.x)

    {:ok, _} = World.join(space.id, user)
    start2 = me(space, user)
    diagonal = walk(space, user, {-1, -1}, 200)

    diagonal_distance =
      :math.sqrt(:math.pow(start2.x - diagonal.x, 2) + :math.pow(start2.y - diagonal.y, 2))

    assert_in_delta straight_distance, diagonal_distance, 0.25
  end

  test "leaving removes the avatar and clears its zone", %{space: space, user: user} do
    World.subscribe(space.id)
    {:ok, _} = World.join(space.id, user)

    :ok = World.leave(space.id, user.id)

    assert World.snapshot(space.id).avatars == []
    assert_receive {:left, id} when id == user.id, 500
  end

  test "the avatar disappears when its client process dies", %{space: space, user: user} do
    parent = self()

    client =
      spawn(fn ->
        {:ok, _} = World.join(space.id, user, self())
        send(parent, :joined)
        Process.sleep(:infinity)
      end)

    assert_receive :joined, 1000
    assert length(World.snapshot(space.id).avatars) == 1

    Process.exit(client, :kill)
    Process.sleep(200)

    assert World.snapshot(space.id).avatars == []
  end

  describe "click to move" do
    # Waits for the avatar to stop, so these don't depend on exact walk timings.
    defp settle(space, user, timeout \\ 4_000) do
      deadline = System.monotonic_time(:millisecond) + timeout
      do_settle(space, user, deadline, nil)
    end

    defp do_settle(space, user, deadline, previous) do
      Process.sleep(120)
      current = me(space, user)

      cond do
        previous && current.x == previous.x && current.y == previous.y -> current
        System.monotonic_time(:millisecond) > deadline -> current
        true -> do_settle(space, user, deadline, current)
      end
    end

    test "walks around a wall into the sealed room", %{space: space, user: user} do
      {:ok, _} = World.join(space.id, user)

      # (3,4) is inside the cell, which can only be entered through the gap
      # at (4,5) — a straight line from spawn runs into the wall.
      World.walk_to(space.id, user.id, {3.5, 4.5})
      avatar = settle(space, user)

      assert avatar.z == "cell", "ended at #{avatar.x},#{avatar.y}"
      assert_in_delta avatar.x, 3.5, 0.4
      assert_in_delta avatar.y, 4.5, 0.4
    end

    test "clicking a wall does nothing", %{space: space, user: user} do
      {:ok, _} = World.join(space.id, user)
      before = me(space, user)

      World.walk_to(space.id, user.id, {0.5, 0.5})
      Process.sleep(300)

      avatar = me(space, user)
      assert_in_delta avatar.x, before.x, 0.01
      assert_in_delta avatar.y, before.y, 0.01
    end

    test "pressing a key abandons the clicked route", %{space: space, user: user} do
      {:ok, _} = World.join(space.id, user)

      World.walk_to(space.id, user.id, {3.5, 4.5})
      Process.sleep(120)

      World.move(space.id, user.id, {1, 0})
      Process.sleep(150)
      World.move(space.id, user.id, {0, 0})

      avatar = settle(space, user)

      refute avatar.z == "cell", "kept following the route after a key press"
    end
  end

  test "two people share the same floor", %{space: space, user: user} do
    other = user_fixture("bob")
    {:ok, _} = World.join(space.id, user)
    {:ok, state} = World.join(space.id, other, spawn(fn -> Process.sleep(:infinity) end))

    assert length(state.avatars) == 2
    # Nobody is stacked exactly on top of anybody else's tile after the nudge.
    assert length(World.zone_occupancy(space.id)[nil]) == 2
  end
end
