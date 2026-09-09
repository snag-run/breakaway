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

    Setup.run(["--space", space.slug, "--no-lobby"])

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

    Setup.run(["--space", space.slug, "--no-lobby"])

    assert output() =~ "reused #cell"
    assert zone(space, "cell").discord_channel_id == "chan-1"
  end

  test "a dry run changes nothing", %{space: space} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, [])
    end)

    Setup.run(["--space", space.slug, "--dry-run", "--no-lobby"])

    assert output() =~ "would create #cell"
    assert zone(space, "cell").discord_channel_id == nil
  end

  test "rooms that are already linked are left alone", %{space: space} do
    bind_zone!(space, "cell", channel_id: "already-there")

    Req.Test.stub(Breakaway.Discord.Client, fn conn -> Req.Test.json(conn, []) end)

    Setup.run(["--space", space.slug, "--no-lobby"])

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

    Setup.run(["--space", space.slug, "--no-lobby"])

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

  # --- the lobby channel --------------------------------------------------------

  test "creates the lobby channel and prints the id to put in .env", %{space: space} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, [])

        "POST" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"name" => name, "type" => 2} = Jason.decode!(body)
          Req.Test.json(conn, %{"id" => "chan-#{name}", "name" => name, "type" => 2})
      end
    end)

    Setup.run(["--space", space.slug])

    out = output()
    assert out =~ "Lobby: created #lobby"
    assert out =~ "DISCORD_LOBBY_CHANNEL_ID=chan-lobby"
  end

  test "names the lobby channel after the office's own lobby zone", %{space: space} do
    Worlds.create_zone!(
      %{
        space_id: space.id,
        name: "The Commons",
        slug: "commons",
        kind: :lobby,
        x: 6,
        y: 6,
        width: 2,
        height: 2,
        accent: "#7c8896"
      },
      authorize?: false
    )

    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, [])

        "POST" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"name" => name} = Jason.decode!(body)
          Req.Test.json(conn, %{"id" => "chan-#{name}", "name" => name, "type" => 2})
      end
    end)

    Setup.run(["--space", space.slug])

    assert output() =~ "Lobby: created #commons"
  end

  test "the lobby channel is never bound to a zone", %{space: space} do
    Worlds.create_zone!(
      %{
        space_id: space.id,
        name: "The Commons",
        slug: "commons",
        kind: :lobby,
        x: 6,
        y: 6,
        width: 2,
        height: 2,
        accent: "#7c8896"
      },
      authorize?: false
    )

    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, [])

        "POST" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"name" => name} = Jason.decode!(body)
          Req.Test.json(conn, %{"id" => "chan-#{name}", "name" => name, "type" => 2})
      end
    end)

    Setup.run(["--space", space.slug])

    # Binding it would drag anyone crossing the commons into a call.
    assert zone(space, "commons").discord_channel_id == nil
  end

  test "reuses a voice channel that already matches the lobby", %{space: space} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, [
            %{"id" => "chan-lobby", "name" => "lobby", "type" => 2, "position" => 0}
          ])

        "POST" ->
          Req.Test.json(conn, %{"id" => "chan-new", "name" => "cell", "type" => 2})
      end
    end)

    Setup.run(["--space", space.slug])

    out = output()
    assert out =~ "Lobby: reused #lobby"
    assert out =~ "DISCORD_LOBBY_CHANNEL_ID=chan-lobby"
  end

  test "leaves the lobby alone when DISCORD_LOBBY_CHANNEL_ID is already set", %{space: space} do
    previous = Application.get_env(:breakaway, :discord)
    Application.put_env(:breakaway, :discord, Keyword.put(previous, :lobby_channel_id, "set-9"))

    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, [])

        "POST" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert %{"name" => "cell"} = Jason.decode!(body)
          Req.Test.json(conn, %{"id" => "chan-new", "name" => "cell", "type" => 2})
      end
    end)

    Setup.run(["--space", space.slug])

    assert output() =~ "already set by DISCORD_LOBBY_CHANNEL_ID"
  end

  test "a dry run does not create the lobby either", %{space: space} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, [])
    end)

    Setup.run(["--space", space.slug, "--dry-run"])

    assert output() =~ "Lobby: would create #lobby"
  end

  # --- grouping into a category -------------------------------------------------

  test "--category creates one and nests every channel under it", %{space: space} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, [])

        "POST" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          case Jason.decode!(body) do
            %{"name" => "Breakaway", "type" => 4} ->
              Req.Test.json(conn, %{"id" => "cat-1", "name" => "Breakaway", "type" => 4})

            %{"name" => name, "type" => 2, "parent_id" => "cat-1"} ->
              Req.Test.json(conn, %{"id" => "chan-#{name}", "name" => name, "type" => 2})
          end
      end
    end)

    Setup.run(["--space", space.slug, "--category", "Breakaway"])

    out = output()
    assert out =~ "Created the Breakaway category"
    assert out =~ "created #cell"
    assert out =~ "Lobby: created #lobby"
  end

  test "--category reuses a category that is already there, whatever its case", %{space: space} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, [
            %{"id" => "cat-9", "name" => "Breakaway", "type" => 4, "position" => 0}
          ])

        "POST" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)
          assert decoded["type"] == 2
          assert decoded["parent_id"] == "cat-9"
          Req.Test.json(conn, %{"id" => "chan-1", "name" => decoded["name"], "type" => 2})
      end
    end)

    Setup.run(["--space", space.slug, "--category", "breakaway"])

    assert output() =~ "Grouping under the existing Breakaway category"
  end

  test "without --category the channels stay at the guild root", %{space: space} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, [])

        "POST" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          refute Map.has_key?(Jason.decode!(body), "parent_id")
          Req.Test.json(conn, %{"id" => "chan-new", "name" => "cell", "type" => 2})
      end
    end)

    Setup.run(["--space", space.slug, "--no-lobby"])

    assert output() =~ "created #cell"
  end

  test "stops before touching any room when the category cannot be created", %{space: space} do
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

    assert_raise Mix.Error, ~r/Manage Channels to create the Breakaway category/, fn ->
      Setup.run(["--space", space.slug, "--category", "Breakaway"])
    end

    assert zone(space, "cell").discord_channel_id == nil
  end

  test "a dry run reports the category without creating it", %{space: space} do
    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, [])
    end)

    Setup.run(["--space", space.slug, "--dry-run", "--category", "Breakaway"])

    assert output() =~ "Would create the Breakaway category"
  end

  test "a blank DISCORD_LOBBY_CHANNEL_ID counts as unset, not as configured", %{space: space} do
    previous = Application.get_env(:breakaway, :discord)
    Application.put_env(:breakaway, :discord, Keyword.put(previous, :lobby_channel_id, ""))

    Req.Test.stub(Breakaway.Discord.Client, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, [])

        "POST" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"name" => name} = Jason.decode!(body)
          Req.Test.json(conn, %{"id" => "chan-#{name}", "name" => name, "type" => 2})
      end
    end)

    Setup.run(["--space", space.slug])

    out = output()
    refute out =~ "already set"
    assert out =~ "DISCORD_LOBBY_CHANNEL_ID=chan-lobby"
  end

  test "a blank DISCORD_GUILD_ID counts as unset, not as configured", %{space: space} do
    previous = Application.get_env(:breakaway, :discord)
    Application.put_env(:breakaway, :discord, Keyword.put(previous, :guild_id, ""))

    assert_raise Mix.Error, ~r/--guild/, fn ->
      Setup.run(["--space", space.slug])
    end
  end
end
