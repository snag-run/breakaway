defmodule Breakaway.Discord.VoiceSyncTest do
  @moduledoc """
  The policy that decides what a zone transition means for Discord. Calls
  `sync/1` directly so the assertions don't race a supervised task.
  """
  use Breakaway.DataCase

  import Breakaway.Fixtures

  alias Breakaway.Discord.VoiceSync
  alias Breakaway.Worlds

  setup do
    previous = Application.get_env(:breakaway, :discord, [])

    Application.put_env(
      :breakaway,
      :discord,
      Keyword.put(previous, :bot_token, "test-bot-token")
    )

    on_exit(fn -> Application.put_env(:breakaway, :discord, previous) end)

    space = small_space_fixture()
    bind_zone!(space, "cell")
    zones = Worlds.list_zones!(query: [filter: [space_id: space.id]], authorize?: false)
    user = user_fixture()

    Phoenix.PubSub.subscribe(Breakaway.PubSub, "user:#{user.id}")

    %{space: space, zones: zones, user: user}
  end

  defp event(ctx, from, to) do
    %{
      space_id: ctx.space.id,
      user_id: ctx.user.id,
      discord_id: ctx.user.discord_id,
      name: ctx.user.display_name,
      from: from,
      to: to,
      zones: ctx.zones
    }
  end

  defp stub(fun), do: Req.Test.stub(Breakaway.Discord.Client, fun)

  test "walking into a linked room moves the member into the channel", ctx do
    stub(fn conn ->
      assert conn.request_path == "/api/v10/guilds/guild-1/members/#{ctx.user.discord_id}"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"channel_id" => "channel-1"}
      Req.Test.json(conn, %{})
    end)

    VoiceSync.sync(event(ctx, nil, "cell"))

    assert_receive {:voice, {:moved, zone}}
    assert zone.slug == "cell"
  end

  test "someone not connected to voice is offered a link instead", ctx do
    stub(fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"message" => "not connected"})
    end)

    VoiceSync.sync(event(ctx, nil, "cell"))

    assert_receive {:voice, {:join_required, zone, url}}
    assert zone.slug == "cell"
    assert url == "https://discord.com/channels/guild-1/channel-1"
  end

  test "a permission problem is surfaced rather than swallowed", ctx do
    stub(fn conn ->
      conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Missing Permissions"})
    end)

    VoiceSync.sync(event(ctx, nil, "cell"))

    assert_receive {:voice, {:failed, _zone, :missing_permission}}
  end

  test "auto_move off means walking in does nothing", ctx do
    bind_zone!(ctx.space, "cell", auto_move: false)
    zones = Worlds.list_zones!(query: [filter: [space_id: ctx.space.id]], authorize?: false)

    stub(fn _conn -> flunk("should not have called Discord") end)

    VoiceSync.sync(%{event(ctx, nil, "cell") | zones: zones})

    refute_receive {:voice, _}, 100
  end

  test "leaving a linked room says so when there is no lobby channel", ctx do
    VoiceSync.sync(event(ctx, "cell", nil))

    assert_receive {:voice, {:left_room, zone}}
    assert zone.slug == "cell"
  end

  test "leaving moves back to the lobby channel when one is configured", ctx do
    previous = Application.get_env(:breakaway, :discord)
    Application.put_env(:breakaway, :discord, Keyword.put(previous, :lobby_channel_id, "lobby-9"))
    on_exit(fn -> Application.put_env(:breakaway, :discord, previous) end)

    stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"channel_id" => "lobby-9"}
      Req.Test.json(conn, %{})
    end)

    VoiceSync.sync(event(ctx, "cell", nil))

    assert_receive {:voice, {:returned_to_lobby, _zone}}
  end

  test "an unlinked meeting room reports that it is not connected", ctx do
    previous = Application.get_env(:breakaway, :discord)
    Application.put_env(:breakaway, :discord, Keyword.delete(previous, :bot_token))
    on_exit(fn -> Application.put_env(:breakaway, :discord, previous) end)

    VoiceSync.sync(event(ctx, nil, "cell"))

    assert_receive {:voice, {:unconfigured, zone}}
    assert zone.slug == "cell"
  end

  test "crossing the open floor with no bot configured stays silent", ctx do
    previous = Application.get_env(:breakaway, :discord)
    Application.put_env(:breakaway, :discord, Keyword.delete(previous, :bot_token))
    on_exit(fn -> Application.put_env(:breakaway, :discord, previous) end)

    VoiceSync.sync(event(ctx, nil, nil))

    refute_receive {:voice, _}, 100
  end
end
