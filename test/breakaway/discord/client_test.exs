defmodule Breakaway.Discord.ClientTest do
  use ExUnit.Case, async: true

  alias Breakaway.Discord.Client

  setup do
    previous = Application.get_env(:breakaway, :discord, [])
    Application.put_env(:breakaway, :discord, Keyword.put(previous, :bot_token, "test-bot-token"))
    on_exit(fn -> Application.put_env(:breakaway, :discord, previous) end)
    :ok
  end

  defp stub(fun), do: Req.Test.stub(Breakaway.Discord.Client, fun)

  test "is configured only when a bot token is present" do
    assert Client.configured?()

    previous = Application.get_env(:breakaway, :discord)
    Application.put_env(:breakaway, :discord, Keyword.delete(previous, :bot_token))
    refute Client.configured?()
    Application.put_env(:breakaway, :discord, previous)
  end

  test "lists only voice and stage channels, in position order" do
    stub(fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v10/guilds/g1/channels"
      assert ["Bot test-bot-token"] = Plug.Conn.get_req_header(conn, "authorization")

      Req.Test.json(conn, [
        %{"id" => "3", "name" => "general", "type" => 0, "position" => 0},
        %{"id" => "2", "name" => "aurora", "type" => 2, "position" => 2, "user_limit" => 8},
        %{"id" => "1", "name" => "all-hands", "type" => 13, "position" => 1}
      ])
    end)

    assert {:ok, channels} = Client.list_voice_channels("g1")
    assert Enum.map(channels, & &1.name) == ["all-hands", "aurora"]
    assert Enum.map(channels, & &1.type) == [:stage, :voice]
  end

  test "moving a member sends the channel id" do
    stub(fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/api/v10/guilds/g1/members/u1"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"channel_id" => "c1"}
      Req.Test.json(conn, %{})
    end)

    assert :ok = Client.move_member("g1", "u1", "c1")
  end

  test "a member who is not in voice is reported distinctly" do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"message" => "Target user is not connected to voice."})
    end)

    assert {:error, :not_in_voice} = Client.move_member("g1", "u1", "c1")
  end

  test "a missing permission is reported distinctly" do
    stub(fn conn ->
      conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Missing Permissions"})
    end)

    assert {:error, :missing_permission} = Client.move_member("g1", "u1", "c1")
  end

  test "disconnecting sends a null channel" do
    stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"channel_id" => nil}
      Req.Test.json(conn, %{})
    end)

    assert :ok = Client.disconnect_member("g1", "u1")
  end

  test "user guilds are fetched with the user's own token" do
    stub(fn conn ->
      assert conn.request_path == "/api/v10/users/@me/guilds"
      assert ["Bearer user-token"] = Plug.Conn.get_req_header(conn, "authorization")
      Req.Test.json(conn, [%{"id" => "g1", "name" => "Acme", "icon" => nil}])
    end)

    assert {:ok, [%{id: "g1", name: "Acme"}]} = Client.user_guilds("user-token")
  end

  test "without a bot token nothing is attempted" do
    previous = Application.get_env(:breakaway, :discord)
    Application.put_env(:breakaway, :discord, Keyword.delete(previous, :bot_token))

    assert {:error, :not_configured} = Client.list_voice_channels("g1")
    assert {:error, :not_configured} = Client.move_member("g1", "u1", "c1")

    Application.put_env(:breakaway, :discord, previous)
  end
end
