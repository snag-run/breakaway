defmodule BreakawayWeb.OfficeLiveTest do
  use BreakawayWeb.ConnCase

  import Phoenix.LiveViewTest
  import Breakaway.Fixtures

  alias Breakaway.World

  setup do
    space = small_space_fixture()

    on_exit(fn ->
      case Registry.lookup(Breakaway.World.Registry, space.id) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Breakaway.World.SpaceSupervisor, pid)
        [] -> :ok
      end
    end)

    %{space: space, user: user_fixture("ada")}
  end

  test "signed-out visitors are sent to sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/office")
  end

  test "the office renders and hands the browser the map", %{conn: conn, user: user, space: space} do
    {:ok, view, html} = conn |> log_in_user(user) |> live(~p"/office")

    assert html =~ "In the office"
    assert html =~ user.display_name

    assert_push_event(view, "office:map", payload)
    assert payload.width == space.width
    assert payload.height == space.height
    assert length(payload.ground) == space.width * space.height
    assert Enum.any?(payload.zones, &(&1.slug == "cell"))
    # The E-key prompts travel with the map so the hint text matches the server.
    assert is_map(payload.interactions)
  end

  test "the person is listed in the roster once they are on the floor", %{conn: conn, user: user} do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/office")

    assert render(view) =~ "Ada"
    assert render(view) =~ "1 here now"
  end

  test "movement intent reaches the simulation", %{conn: conn, user: user, space: space} do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/office")

    before = World.snapshot(space.id).avatars |> hd()

    render_hook(view, "move", %{"dx" => 0, "dy" => -1})
    Process.sleep(300)
    render_hook(view, "move", %{"dx" => 0, "dy" => 0})
    Process.sleep(120)

    after_move = World.snapshot(space.id).avatars |> hd()
    assert after_move.y < before.y
    assert after_move.d == :up
  end

  test "chat reaches the room and the sender's composer is cleared", %{conn: conn, user: user} do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/office")

    render_hook(view, "say", %{"text" => "morning all"})

    assert render(view) =~ "morning all"
    assert_push_event(view, "office:say", %{text: "morning all"})
    assert_push_event(view, "office:sent", %{})
  end

  test "blank messages are ignored", %{conn: conn, user: user} do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/office")

    render_hook(view, "say", %{"text" => "   "})

    refute_push_event(view, "office:say", %{}, 100)
  end

  test "chat is heard in your room, not across the whole floor", %{
    conn: conn,
    user: user,
    space: space
  } do
    listener = user_fixture("bob")

    {:ok, speaker_view, _} = conn |> log_in_user(user) |> live(~p"/office")
    {:ok, listener_view, _} = build_conn() |> log_in_user(listener) |> live(~p"/office")
    Process.sleep(150)

    # Both start outside any zone, so they can hear each other.
    render_hook(speaker_view, "say", %{"text" => "on the floor"})
    assert render(listener_view) =~ "on the floor"

    # Move the listener into the cell; the speaker stays outside.
    World.move(space.id, listener.id, {0, -1})
    Process.sleep(400)
    World.move(space.id, listener.id, {-1, 0})
    Process.sleep(500)
    World.move(space.id, listener.id, {0, 0})
    Process.sleep(200)

    assert World.snapshot(space.id).avatars
           |> Enum.find(&(&1.id == listener.id))
           |> Map.get(:z) == "cell"

    render_hook(speaker_view, "say", %{"text" => "cannot hear this"})
    Process.sleep(100)

    refute render(listener_view) =~ "cannot hear this"
    assert render(speaker_view) =~ "cannot hear this"
  end

  test "two people see each other in the room", %{conn: conn, user: user} do
    other = user_fixture("bob")

    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/office")
    {:ok, _other_view, _} = build_conn() |> log_in_user(other) |> live(~p"/office")

    # Give the tick a moment to broadcast the new arrival.
    Process.sleep(200)

    html = render(view)
    assert html =~ "Ada"
    assert html =~ "Bob"
    assert html =~ "2 here now"
  end

  describe "profile editor" do
    test "opens from the footer and shows your current details", %{conn: conn, user: user} do
      {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/office")

      html = view |> element("button", "Ada") |> render_click()

      assert html =~ "How you look"
      assert html =~ ~s(value="Ada")
    end

    test "saving updates the person and everyone else's view of them",
         %{conn: conn, user: user, space: space} do
      {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/office")
      render_click(view, "edit_profile", %{})

      html =
        render_submit(view, "save_profile", %{
          "display_name" => "Ada L",
          "status_message" => "Heads down until 3",
          "avatar_palette" => "3"
        })

      # The editor closes and the sidebar shows the new name.
      refute html =~ "How you look"
      assert html =~ "Ada L"

      # ...and so does the floor, without walking out and back in.
      Process.sleep(150)
      avatar = World.snapshot(space.id).avatars |> hd()
      assert avatar.n == "Ada L"
      assert avatar.p == 3
      assert avatar.s == "Heads down until 3"
    end

    test "clearing the status removes it rather than storing a blank",
         %{conn: conn, user: user} do
      {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/office")

      render_submit(view, "save_profile", %{
        "display_name" => "Ada",
        "status_message" => "busy",
        "avatar_palette" => "0"
      })

      render_submit(view, "save_profile", %{
        "display_name" => "Ada",
        "status_message" => "   ",
        "avatar_palette" => "0"
      })

      user = Ash.get!(Breakaway.Accounts.User, user.id, authorize?: false)
      assert user.status_message == nil
    end

    test "a nonsense palette falls back rather than crashing", %{conn: conn, user: user} do
      {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/office")

      render_submit(view, "save_profile", %{
        "display_name" => "Ada",
        "status_message" => "",
        "avatar_palette" => "not-a-number"
      })

      user = Ash.get!(Breakaway.Accounts.User, user.id, authorize?: false)
      assert user.avatar_palette == 0
    end
  end

  test "leaving the page takes the avatar off the floor", %{conn: conn, user: user, space: space} do
    {:ok, view, _} = conn |> log_in_user(user) |> live(~p"/office")
    assert length(World.snapshot(space.id).avatars) == 1

    GenServer.stop(view.pid)
    Process.sleep(200)

    assert World.snapshot(space.id).avatars == []
  end
end
