defmodule Mix.Tasks.Breakaway.Discord.SetupTest do
  use Breakaway.DataCase

  import Breakaway.Fixtures

  alias Breakaway.Worlds
  alias Mix.Tasks.Breakaway.Discord.Setup

  setup do
    previous_discord = Application.get_env(:breakaway, :discord, [])

    Application.put_env(
      :breakaway,
      :discord,
      previous_discord
      |> Keyword.put(:bot_token, "test-bot-token")
      |> Keyword.put(:guild_id, "guild-9")
    )

    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Application.put_env(:breakaway, :discord, previous_discord)
      Mix.shell(shell)
    end)

    %{space: small_space_fixture()}
  end

  defp zone(space, slug) do
    Worlds.list_zones!(query: [filter: [space_id: space.id, slug: slug]], authorize?: false)
    |> hd()
  end

  defp output do
    Stream.repeatedly(fn ->
      receive do
        {:mix_shell, _kind, [text]} -> text
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
    |> Enum.join("\n")
  end

  test "creates a channel for a room that has none, and binds it", %{space: space} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v10/guilds/guild-9/channels"} ->
          Req.Test.json(conn, [])

        {"POST", "/api/v10/guilds/guild-9/channels"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert %{"name" => "cell", "type" => 2} = Jason.decode!(body)
          Req.Test.json(conn, %{"id" => "chan-new", "name" => "cell", "type" => 2})
      end
    end)

    Setup.run(["--space", space.slug])

    assert output() =~ "created #cell"

    bound = zone(space, "cell")
    assert bound.discord_channel_id == "chan-new"
    assert bound.discord_guild_id == "guild-9"
    assert bound.auto_move
  end

  test "reuses a voice channel that already has the right name", %{space: space} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, [
            %{"id" => "chan-1", "name" => "cell", "type" => 2, "position" => 0}
          ])

        "POST" ->
          flunk("should not have created a channel that already exists")
      end
    end)

    Setup.run(["--space", space.slug])

    assert output() =~ "reused #cell"
    assert zone(space, "cell").discord_channel_id == "chan-1"
  end

  test "a dry run changes nothing", %{space: space} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, [])
    end)

    Setup.run(["--space", space.slug, "--dry-run"])

    assert output() =~ "would create #cell"
    assert zone(space, "cell").discord_channel_id == nil
  end

  test "rooms that are already linked are left alone", %{space: space} do
    bind_zone!(space, "cell", channel_id: "already-there")

    Req.Test.stub(Breakaway.Discord.Client, fn conn -> Req.Test.json(conn, []) end)

    Setup.run(["--space", space.slug])

    assert output() =~ "Nothing to link"
    assert zone(space, "cell").discord_channel_id == "already-there"
  end

  test "says what to do when the bot needs Manage Channels", %{space: space} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, [])

        "POST" ->
          conn
          |> Plug.Conn.put_status(403)
          |> Req.Test.json(%{"message" => "Missing Permissions"})
      end
    end)

    Setup.run(["--space", space.slug])

    assert output() =~ "needs Manage Channels"
    assert zone(space, "cell").discord_channel_id == nil
  end

  test "refuses clearly without a bot token", %{space: space} do
    previous = Application.get_env(:breakaway, :discord)
    Application.put_env(:breakaway, :discord, Keyword.delete(previous, :bot_token))

    assert_raise Mix.Error, ~r/DISCORD_BOT_TOKEN/, fn ->
      Setup.run(["--space", space.slug])
    end
  end

  test "refuses clearly without a guild", %{space: space} do
    previous = Application.get_env(:breakaway, :discord)
    Application.put_env(:breakaway, :discord, Keyword.delete(previous, :guild_id))

    assert_raise Mix.Error, ~r/--guild/, fn ->
      Setup.run(["--space", space.slug])
    end
  end
end
