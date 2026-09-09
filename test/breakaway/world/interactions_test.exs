defmodule Breakaway.World.InteractionsTest do
  use Breakaway.DataCase

  import Breakaway.Fixtures

  alias Breakaway.World
  alias Breakaway.World.Interactions
  alias Breakaway.Worlds
  alias Breakaway.Worlds.Atlas

  describe "the interaction table" do
    test "only refers to props that exist in the spritesheet" do
      known = MapSet.new(Atlas.prop_names())

      for kind <- Map.keys(Interactions.prompts()) do
        assert MapSet.member?(known, kind), "#{kind} has a prompt but no sprite"
      end
    end

    test "every interactable prop has both a prompt and an activity" do
      for {kind, prompt} <- Interactions.prompts() do
        assert is_binary(prompt) and prompt != ""
        assert is_binary(Interactions.activity(kind))
        assert Interactions.interactable?(kind)
      end
    end

    test "scenery is not interactable" do
      refute Interactions.interactable?(:lamp)
      assert Interactions.activity(:lamp) == nil
    end

    test "seats are a subset of interactable furniture" do
      for kind <- [:chair, :office_chair, :couch, :beanbag] do
        assert Interactions.seat?(kind)
        assert Interactions.interactable?(kind)
      end

      refute Interactions.seat?(:coffee_machine)
      refute Interactions.seat?(:whiteboard)
    end
  end

  describe "sitting down" do
    setup do
      space = small_space_fixture()

      # A chair immediately to the right of the spawn tile (5,7).
      Worlds.create_prop!(
        %{space_id: space.id, kind: :chair, x: 6, y: 7, solid: true},
        authorize?: false
      )

      on_exit(fn ->
        case Registry.lookup(Breakaway.World.Registry, space.id) do
          [{pid, _}] -> DynamicSupervisor.terminate_child(Breakaway.World.SpaceSupervisor, pid)
          [] -> :ok
        end
      end)

      %{space: space, user: user_fixture()}
    end

    test "sitting puts the avatar on the chair", %{space: space, user: user} do
      {:ok, _} = World.join(space.id, user)

      assert {:ok, "Sitting"} = World.interact(space.id, user.id)
      Process.sleep(80)

      avatar = me(space, user)
      assert avatar.sit == true
      assert avatar.a == "Sitting"
      # Snapped to the middle of the chair, facing the camera.
      assert_in_delta avatar.x, 6.5, 0.01
      assert_in_delta avatar.y, 7.5, 0.01
      assert avatar.d == :down
    end

    test "you sit the way the chair is pointing", %{space: space, user: user} do
      # A second chair, turned to face up the way a desk chair is.
      Worlds.create_prop!(
        %{space_id: space.id, kind: :office_chair, x: 4, y: 8, solid: true, facing: :up},
        authorize?: false
      )

      case Registry.lookup(Breakaway.World.Registry, space.id) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Breakaway.World.SpaceSupervisor, pid)
        [] -> :ok
      end

      {:ok, _} = World.join(space.id, user)

      # Walk down-left so the up-facing chair at (4,8) is the nearest seat.
      World.move(space.id, user.id, {-1, 1})
      Process.sleep(180)
      World.move(space.id, user.id, {0, 0})
      Process.sleep(120)

      assert {:ok, "Sitting"} = World.interact(space.id, user.id)
      Process.sleep(80)

      avatar = me(space, user)
      assert avatar.sit
      assert avatar.d == :up, "should face the way the chair points"
      assert_in_delta avatar.x, 4.5, 0.01
      assert_in_delta avatar.y, 8.5, 0.01
    end

    test "standing up moves off the chair rather than leaving you inside it",
         %{space: space, user: user} do
      {:ok, _} = World.join(space.id, user)
      {:ok, "Sitting"} = World.interact(space.id, user.id)

      assert {:ok, nil} = World.interact(space.id, user.id)
      Process.sleep(80)

      avatar = me(space, user)
      refute avatar.sit
      assert avatar.a == nil
      # The chair is solid, so the avatar cannot still be standing in its tile.
      refute trunc(avatar.x) == 6 and trunc(avatar.y) == 7
    end

    test "walking gets you out of the chair", %{space: space, user: user} do
      {:ok, _} = World.join(space.id, user)
      {:ok, "Sitting"} = World.interact(space.id, user.id)

      World.move(space.id, user.id, {-1, 0})
      Process.sleep(300)
      World.move(space.id, user.id, {0, 0})
      Process.sleep(120)

      avatar = me(space, user)
      refute avatar.sit
      assert avatar.a == nil
      assert avatar.x < 6.0, "should have walked away from the chair"
    end
  end

  describe "using furniture" do
    setup do
      space = small_space_fixture()

      # A coffee machine right next to the spawn tile (5,7).
      Worlds.create_prop!(
        %{space_id: space.id, kind: :coffee_machine, x: 6, y: 7, solid: false},
        authorize?: false
      )

      on_exit(fn ->
        case Registry.lookup(Breakaway.World.Registry, space.id) do
          [{pid, _}] -> DynamicSupervisor.terminate_child(Breakaway.World.SpaceSupervisor, pid)
          [] -> :ok
        end
      end)

      %{space: space, user: user_fixture()}
    end

    defp me(space, user),
      do: World.snapshot(space.id).avatars |> Enum.find(&(&1.id == user.id))

    test "pressing E next to something starts that activity", %{space: space, user: user} do
      {:ok, _} = World.join(space.id, user)
      before = me(space, user)

      assert {:ok, "Getting coffee"} = World.interact(space.id, user.id)
      Process.sleep(80)

      avatar = me(space, user)
      assert avatar.a == "Getting coffee"
      # A coffee machine is not a seat: you stay standing where you are.
      refute avatar.sit
      assert_in_delta avatar.x, before.x, 0.01
      assert_in_delta avatar.y, before.y, 0.01
    end

    test "pressing E again stops it", %{space: space, user: user} do
      {:ok, _} = World.join(space.id, user)
      {:ok, _} = World.interact(space.id, user.id)

      assert {:ok, nil} = World.interact(space.id, user.id)
      Process.sleep(80)
      assert me(space, user).a == nil
    end

    test "pressing E with nothing nearby does nothing", %{space: space, user: user} do
      {:ok, _} = World.join(space.id, user)

      World.move(space.id, user.id, {-1, 0})
      Process.sleep(500)
      World.move(space.id, user.id, {0, 0})
      Process.sleep(100)

      assert {:error, :nothing_nearby} = World.interact(space.id, user.id)
    end

    test "walking away ends the activity", %{space: space, user: user} do
      {:ok, _} = World.join(space.id, user)
      {:ok, "Getting coffee"} = World.interact(space.id, user.id)

      World.move(space.id, user.id, {-1, 0})
      Process.sleep(500)
      World.move(space.id, user.id, {0, 0})
      Process.sleep(120)

      assert me(space, user).a == nil
    end
  end
end
