defmodule Breakaway.Discord.VoiceTrackerTest do
  use Breakaway.DataCase

  import Breakaway.Fixtures

  alias Breakaway.Discord.VoiceTracker
  alias Breakaway.World

  setup do
    previous = Application.get_env(:breakaway, :discord, [])
    Application.put_env(:breakaway, :discord, Keyword.put(previous, :bot_token, "test-bot-token"))
    on_exit(fn -> Application.put_env(:breakaway, :discord, previous) end)

    space = small_space_fixture()
    bind_zone!(space, "cell")

    on_exit(fn ->
      case Registry.lookup(Breakaway.World.Registry, space.id) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Breakaway.World.SpaceSupervisor, pid)
        [] -> :ok
      end
    end)

    user = user_fixture()
    {:ok, _} = World.join(space.id, user)

    %{space: space, user: user}
  end

  defp me(space, user),
    do: World.snapshot(space.id).avatars |> Enum.find(&(&1.id == user.id))

  defp targets(space), do: World.voice_targets(space.id)

  test "everyone on the floor is asked about, once a guild is known", %{space: space, user: user} do
    assert [target] = targets(space)
    assert target.user_id == user.id
    assert target.discord_id == user.discord_id
    assert target.guild_id == "guild-1"
  end

  test "no guild bound means nobody is polled" do
    bare = small_space_fixture()
    user = user_fixture()
    {:ok, _} = World.join(bare.id, user)

    assert World.voice_targets(bare.id) == []
  end

  test "being in a call shows on the floor", %{space: space, user: user} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      assert conn.request_path == "/api/v10/guilds/guild-1/voice-states/#{user.discord_id}"
      Req.Test.json(conn, %{"channel_id" => "channel-1", "self_mute" => false})
    end)

    VoiceTracker.poll_space(space.id, targets(space))
    Process.sleep(120)

    avatar = me(space, user)
    assert avatar.v, "expected to be shown as in a call"
    refute avatar.mu
  end

  test "muting is reflected", %{space: space, user: user} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      Req.Test.json(conn, %{"channel_id" => "channel-1", "self_mute" => true})
    end)

    VoiceTracker.poll_space(space.id, targets(space))
    Process.sleep(120)

    assert me(space, user).mu
  end

  test "hanging up clears the badge", %{space: space, user: user} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      Req.Test.json(conn, %{"channel_id" => "channel-1"})
    end)

    VoiceTracker.poll_space(space.id, targets(space))
    Process.sleep(120)
    assert me(space, user).v

    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Unknown Voice State"})
    end)

    VoiceTracker.poll_space(space.id, targets(space))
    Process.sleep(120)

    refute me(space, user).v
  end

  test "a failed lookup leaves what we already believed", %{space: space, user: user} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      Req.Test.json(conn, %{"channel_id" => "channel-1"})
    end)

    VoiceTracker.poll_space(space.id, targets(space))
    Process.sleep(120)
    assert me(space, user).v

    # Discord unreachable — not the same as "they hung up".
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "oops"})
    end)

    assert VoiceTracker.poll_space(space.id, targets(space)) == %{}
    Process.sleep(120)

    assert me(space, user).v, "a failed lookup wrongly marked them as hung up"
  end

  test "joining the call from Discord walks you into the room", %{space: space, user: user} do
    assert me(space, user).z == nil

    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      Req.Test.json(conn, %{"channel_id" => "channel-1"})
    end)

    VoiceTracker.poll_space(space.id, targets(space))

    avatar = walk_until_still(space, user)
    assert avatar.z == "cell", "ended at #{avatar.x},#{avatar.y}"
  end

  defp walk_until_still(space, user, previous \\ nil, remaining \\ 40) do
    Process.sleep(120)
    current = me(space, user)

    cond do
      remaining == 0 ->
        current

      previous && current.x == previous.x && current.y == previous.y && previous.z != nil ->
        current

      true ->
        walk_until_still(space, user, current, remaining - 1)
    end
  end
end
