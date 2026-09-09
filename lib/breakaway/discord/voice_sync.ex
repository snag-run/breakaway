defmodule Breakaway.Discord.VoiceSync do
  @moduledoc """
  Turns "this avatar walked into a room" into "this person is in that call".

  Called from the space simulation on every zone transition. The Discord request
  happens on a supervised task so a slow or failing API call can never stall the
  game tick, and the outcome is pushed back to that user's LiveView so the UI can
  explain what happened (or offer a join link when we can't move them ourselves).
  """

  require Logger

  alias Breakaway.Discord.Client

  @doc "Fire-and-forget entry point used by `Breakaway.World.SpaceServer`."
  def handle_zone_change(event) do
    Task.Supervisor.start_child(Breakaway.TaskSupervisor, fn -> sync(event) end)
    :ok
  end

  @doc "The synchronous core — called directly in tests."
  def sync(%{from: from, to: to, zones: zones} = event) do
    from_zone = find_zone(zones, from)
    to_zone = find_zone(zones, to)

    cond do
      # Only speak up about missing configuration when somebody walks into a
      # room that is supposed to have a call — not on every step across the floor.
      not Client.configured?() and meeting?(to_zone) ->
        notify(event, {:unconfigured, to_zone})

      not Client.configured?() ->
        :ok

      linked_and_auto?(to_zone) ->
        enter(event, to_zone)

      linked_and_auto?(from_zone) ->
        exit_room(event, from_zone)

      true ->
        :ok
    end
  end

  # --- entering ---------------------------------------------------------------

  defp enter(event, zone) do
    if Map.get(event, :voice_channel_id) == zone.discord_channel_id do
      # They joined from Discord and the office walked them in — no move needed.
      :ok
    else
      do_enter(event, zone)
    end
  end

  defp do_enter(event, zone) do
    case Client.move_member(zone.discord_guild_id, event.discord_id, zone.discord_channel_id) do
      :ok ->
        notify(event, {:moved, zone})

      {:error, :not_in_voice} ->
        # Discord can only move somebody already connected to voice, so hand the
        # user a link and let them make the first hop themselves.
        notify(event, {:join_required, zone, channel_url(zone)})

      {:error, reason} ->
        Logger.warning("voice move failed for #{event.name} -> #{zone.slug}: #{inspect(reason)}")
        notify(event, {:failed, zone, reason})
    end
  end

  @doc """
  Somebody is in a room's call, is not in that room, and is not walking there.

  They cancelled the walk by taking the keys, or never got in at all. Hand them
  back to the lobby rather than leaving them talking into a room they are not
  standing in.
  """
  def handle_abandoned_call(event) do
    Task.Supervisor.start_child(Breakaway.TaskSupervisor, fn -> abandon(event) end)
    :ok
  end

  @doc "The synchronous core of `handle_abandoned_call/1` — called directly in tests."
  def abandon(%{zone: zone} = event), do: return_to_lobby(event, zone)

  # --- leaving ----------------------------------------------------------------

  # Nothing to do for somebody who was never in the call to begin with.
  defp exit_room(%{voice_channel_id: nil}, _from_zone), do: :ok

  defp exit_room(event, from_zone) do
    if in_another_rooms_call?(event, from_zone) do
      # They joined a different room's call from Discord and the office is
      # walking them over. Returning them to the lobby on the way out of the old
      # room would undo the very thing they just asked for.
      :ok
    else
      return_to_lobby(event, from_zone)
    end
  end

  # The channel they are actually in belongs to some other room on this floor.
  defp in_another_rooms_call?(event, from_zone) do
    case Map.get(event, :voice_channel_id) do
      # Not in a call at all. Matching on nil would pair them with the first
      # unbound zone on the floor, which is every zone that has no channel.
      nil ->
        false

      channel_id ->
        case Enum.find(event.zones, &(&1.discord_channel_id == channel_id)) do
          nil -> false
          zone -> zone.slug != from_zone.slug
        end
    end
  end

  defp return_to_lobby(event, from_zone) do
    case lobby_channel_id() do
      nil ->
        # Nothing configured to fall back to — leave the call alone rather than
        # yanking somebody out of a conversation they may still want.
        notify(event, {:left_room, from_zone})

      lobby_id ->
        case Client.move_member(from_zone.discord_guild_id, event.discord_id, lobby_id) do
          :ok -> notify(event, {:returned_to_lobby, from_zone})
          {:error, :not_in_voice} -> :ok
          {:error, reason} -> notify(event, {:failed, from_zone, reason})
        end
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp linked_and_auto?(nil), do: false

  defp linked_and_auto?(zone),
    do: is_binary(zone.discord_channel_id) and is_binary(zone.discord_guild_id) and zone.auto_move

  defp meeting?(%{kind: :meeting}), do: true
  defp meeting?(_), do: false

  defp find_zone(_zones, nil), do: nil
  defp find_zone(zones, slug), do: Enum.find(zones, &(&1.slug == slug))

  @doc "Deep link that opens the channel in the Discord client."
  def channel_url(%{discord_guild_id: guild, discord_channel_id: channel}),
    do: "https://discord.com/channels/#{guild}/#{channel}"

  defp lobby_channel_id, do: Application.get_env(:breakaway, :discord, [])[:lobby_channel_id]

  defp notify(event, payload) do
    Phoenix.PubSub.broadcast(
      Breakaway.PubSub,
      "user:#{event.user_id}",
      {:voice, payload}
    )
  end
end
