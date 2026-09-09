defmodule BreakawayWeb.DiscordSettingsLive do
  @moduledoc """
  Binds meeting rooms to Discord voice channels.

  Guilds are listed with the signed-in user's own OAuth token; channels are
  listed with the bot token, because only the bot can see (and later move people
  between) voice channels.
  """
  use BreakawayWeb, :live_view

  alias Breakaway.Discord.Client
  alias Breakaway.Worlds

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    space = default_space()
    zones = if space, do: list_zones(space), else: []

    guilds =
      case user.discord_access_token && Client.user_guilds(user.discord_access_token) do
        {:ok, guilds} -> guilds
        _ -> []
      end

    selected =
      configured_guild_id() ||
        Enum.find_value(zones, & &1.discord_guild_id) ||
        (List.first(guilds) || %{})[:id]

    {:ok,
     socket
     |> assign(
       space: space,
       zones: zones,
       guilds: guilds,
       selected_guild: selected,
       bot_configured?: Client.configured?(),
       page_title: "Discord"
     )
     |> load_channels(selected)}
  end

  @impl true
  def handle_event("select_guild", %{"guild_id" => guild_id}, socket) do
    {:noreply, socket |> assign(selected_guild: guild_id) |> load_channels(guild_id)}
  end

  def handle_event("bind", %{"zone_id" => zone_id, "channel_id" => ""}, socket) do
    unbind(socket, zone_id)
  end

  def handle_event("bind", %{"zone_id" => zone_id, "channel_id" => channel_id}, socket) do
    zone = Enum.find(socket.assigns.zones, &(&1.id == zone_id))
    channel = Enum.find(socket.assigns.channels, &(&1.id == channel_id))

    case Worlds.bind_discord_channel(
           zone,
           %{
             discord_guild_id: socket.assigns.selected_guild,
             discord_channel_id: channel_id,
             discord_channel_name: channel && channel.name,
             auto_move: zone.auto_move
           },
           actor: socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply, socket |> reload_zones() |> put_flash(:info, "#{zone.name} is linked.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Could not link: #{Exception.message(error)}")}
    end
  end

  def handle_event("unbind", %{"zone_id" => zone_id}, socket), do: unbind(socket, zone_id)

  def handle_event("toggle_auto", %{"zone_id" => zone_id}, socket) do
    zone = Enum.find(socket.assigns.zones, &(&1.id == zone_id))

    case Worlds.bind_discord_channel(
           zone,
           %{
             discord_guild_id: zone.discord_guild_id,
             discord_channel_id: zone.discord_channel_id,
             discord_channel_name: zone.discord_channel_name,
             auto_move: !zone.auto_move
           },
           actor: socket.assigns.current_user
         ) do
      {:ok, _} -> {:noreply, reload_zones(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not update that room.")}
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp unbind(socket, zone_id) do
    zone = Enum.find(socket.assigns.zones, &(&1.id == zone_id))

    case Worlds.unbind_discord_channel(zone, %{}, actor: socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply, socket |> reload_zones() |> put_flash(:info, "#{zone.name} unlinked.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not unlink that room.")}
    end
  end

  defp load_channels(socket, nil), do: assign(socket, channels: [], channel_error: nil)

  defp load_channels(socket, guild_id) do
    if Client.configured?() do
      case Client.list_voice_channels(guild_id) do
        {:ok, channels} ->
          assign(socket, channels: channels, channel_error: nil)

        {:error, reason} ->
          assign(socket, channels: [], channel_error: describe(reason))
      end
    else
      assign(socket, channels: [], channel_error: nil)
    end
  end

  defp describe({:http, 401, _}), do: "The bot token was rejected (401)."
  defp describe({:http, 403, _}), do: "The bot cannot see that server's channels (403)."
  defp describe({:http, 404, _}), do: "The bot is not in that server (404)."
  defp describe(:not_configured), do: "No bot token is configured."
  defp describe(reason), do: "Discord error: #{inspect(reason)}"

  defp reload_zones(socket) do
    assign(socket, zones: list_zones(socket.assigns.space))
  end

  defp default_space do
    case Worlds.list_spaces(authorize?: false) do
      {:ok, [space | _]} -> space
      _ -> nil
    end
  end

  defp list_zones(nil), do: []

  defp list_zones(space) do
    case Worlds.list_zones(query: [filter: [space_id: space.id]], authorize?: false) do
      {:ok, zones} -> Enum.sort_by(zones, &{&1.kind != :meeting, &1.name})
      _ -> []
    end
  end

  defp configured_guild_id, do: Application.get_env(:breakaway, :discord, [])[:guild_id]
end
