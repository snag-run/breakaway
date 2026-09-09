defmodule Breakaway.Discord.Client do
  @moduledoc """
  Thin wrapper over the Discord HTTP API for the bits this app needs: listing a
  guild's voice channels, seeing who is connected to voice, and moving members
  between channels.

  Every call needs a bot token (`DISCORD_BOT_TOKEN`) for a bot that is in the
  guild and holds **Move Members**. Calls return `{:error, reason}` rather than
  raising — Discord being unreachable must never take the office down.
  """

  require Logger

  @default_base "https://discord.com/api/v10"

  @doc "Voice channels (type 2) and stage channels (type 13) in a guild."
  def list_voice_channels(guild_id) do
    case request(:get, "/guilds/#{guild_id}/channels") do
      {:ok, channels} when is_list(channels) ->
        {:ok,
         channels
         |> Enum.filter(&(&1["type"] in [2, 13]))
         |> Enum.map(
           &%{
             id: &1["id"],
             name: &1["name"],
             type: if(&1["type"] == 13, do: :stage, else: :voice),
             position: &1["position"],
             user_limit: &1["user_limit"]
           }
         )
         |> Enum.sort_by(& &1.position)}

      other ->
        other
    end
  end

  @doc """
  Create a voice channel in a guild. Needs the bot to hold **Manage Channels**.
  """
  def create_voice_channel(guild_id, name, opts \\ []) do
    body =
      %{name: name, type: 2}
      |> then(&if(opts[:parent_id], do: Map.put(&1, :parent_id, opts[:parent_id]), else: &1))
      |> then(&if(opts[:user_limit], do: Map.put(&1, :user_limit, opts[:user_limit]), else: &1))

    case request(:post, "/guilds/#{guild_id}/channels", body) do
      {:ok, channel} ->
        {:ok, %{id: channel["id"], name: channel["name"], type: :voice}}

      {:error, {:http, 403, _}} ->
        {:error, :missing_permission}

      other ->
        other
    end
  end

  @doc """
  Move a member who is already connected to voice into `channel_id`.

  Discord cannot pull somebody into a call who has no voice connection — that
  returns `{:error, :not_in_voice}` so the caller can offer a join link instead.
  """
  def move_member(guild_id, user_id, channel_id) do
    case request(:patch, "/guilds/#{guild_id}/members/#{user_id}", %{channel_id: channel_id}) do
      {:ok, _} -> :ok
      {:error, {:http, 400, _}} -> {:error, :not_in_voice}
      {:error, {:http, 403, _}} -> {:error, :missing_permission}
      {:error, {:http, 404, _}} -> {:error, :not_a_member}
      other -> other
    end
  end

  @doc "Disconnect a member from voice entirely."
  def disconnect_member(guild_id, user_id) do
    case request(:patch, "/guilds/#{guild_id}/members/#{user_id}", %{channel_id: nil}) do
      {:ok, _} -> :ok
      {:error, {:http, 400, _}} -> {:error, :not_in_voice}
      other -> other
    end
  end

  @doc "The member's current voice state, or `{:error, :not_in_voice}`."
  def voice_state(guild_id, user_id, opts \\ []) do
    case request(:get, "/guilds/#{guild_id}/voice-states/#{user_id}", nil, opts) do
      {:ok, %{"channel_id" => nil}} -> {:error, :not_in_voice}
      {:ok, state} -> {:ok, state}
      {:error, {:http, 404, _}} -> {:error, :not_in_voice}
      other -> other
    end
  end

  @doc """
  Where a member is connected, normalised for the office.

  `{:ok, nil}` means "we asked and they are not in a call", which is different
  from `{:error, reason}` meaning "we could not find out".
  """
  def connection(guild_id, user_id) do
    # Polled repeatedly, so a failure should be dropped and picked up on the
    # next round rather than retried behind everyone else's lookup.
    case voice_state(guild_id, user_id, retry: false) do
      {:ok, state} ->
        {:ok,
         %{
           channel_id: state["channel_id"],
           muted?: !!(state["mute"] || state["self_mute"]),
           deafened?: !!(state["deaf"] || state["self_deaf"])
         }}

      {:error, :not_in_voice} ->
        {:ok, nil}

      other ->
        other
    end
  end

  @doc "Guilds the signed-in user belongs to, using *their* OAuth access token."
  def user_guilds(access_token) do
    case request(:get, "/users/@me/guilds", nil, authorization: "Bearer #{access_token}") do
      {:ok, guilds} when is_list(guilds) ->
        {:ok, Enum.map(guilds, &%{id: &1["id"], name: &1["name"], icon: &1["icon"]})}

      other ->
        other
    end
  end

  @doc "Whether a bot token is configured at all."
  def configured?, do: is_binary(bot_token()) and bot_token() != ""

  # --- transport --------------------------------------------------------------

  defp request(method, path, body \\ nil, opts \\ []) do
    authorization = Keyword.get(opts, :authorization) || bot_authorization()

    cond do
      is_nil(authorization) ->
        {:error, :not_configured}

      true ->
        [
          method: method,
          url: base_url() <> path,
          headers: [{"authorization", authorization}],
          receive_timeout: 8_000,
          retry: Keyword.get(opts, :retry, :transient),
          max_retries: 2
        ]
        |> then(&if(body, do: Keyword.put(&1, :json, body), else: &1))
        |> Keyword.merge(req_options())
        |> Req.request()
        |> handle_response(method, path)
    end
  end

  defp handle_response({:ok, %{status: status, body: body}}, _method, _path)
       when status in 200..299,
       do: {:ok, body}

  defp handle_response({:ok, %{status: status, body: body}}, method, path) do
    Logger.warning("Discord #{method} #{path} -> #{status}: #{inspect(body)}")
    {:error, {:http, status, body}}
  end

  defp handle_response({:error, reason}, method, path) do
    Logger.warning("Discord #{method} #{path} failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp bot_authorization do
    case bot_token() do
      token when is_binary(token) and token != "" -> "Bot " <> token
      _ -> nil
    end
  end

  defp bot_token, do: config()[:bot_token]
  defp base_url, do: config()[:api_base] || @default_base
  # Lets tests inject a Req stub without a network round trip.
  defp req_options, do: Application.get_env(:breakaway, :discord_req_options, [])
  defp config, do: Application.get_env(:breakaway, :discord, [])
end
