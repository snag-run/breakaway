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

      assert {:ok, "Getting coffee"} = World.interact(space.id, user.id)
      Process.sleep(80)
      assert me(space, user).a == "Getting coffee"
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
