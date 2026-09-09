defmodule Mix.Tasks.Breakaway.Discord.Setup do
  @shortdoc "Creates and binds Discord voice channels for each meeting room"
  @moduledoc """
  Wires the office up to a Discord server in one go.

  For every meeting room that isn't linked yet it reuses a voice channel whose
  name already matches, and creates one if there isn't. Rooms that are already
  bound are left alone, so this is safe to re-run after adding a room.

      mix breakaway.discord.setup
      mix breakaway.discord.setup --guild 123456789
      mix breakaway.discord.setup --dry-run
      mix breakaway.discord.setup --all          # social and focus rooms too

  Needs `DISCORD_BOT_TOKEN` and a guild the bot is in, holding **Manage
  Channels** (to create) and **Move Members** (to move people once it's live).
  """
  use Mix.Task

  alias Breakaway.Discord.Client
  alias Breakaway.Worlds

  @requirements ["app.start"]

  @switches [guild: :string, dry_run: :boolean, all: :boolean, space: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: @switches)

    with :ok <- check_configured(),
         {:ok, guild_id} <- resolve_guild(opts),
         {:ok, space} <- resolve_space(opts),
         {:ok, channels} <- Client.list_voice_channels(guild_id) do
      space
      |> rooms(opts)
      |> case do
        [] ->
          Mix.shell().info("Nothing to link — every room already has a channel.")

        rooms ->
          Mix.shell().info("Linking #{length(rooms)} room(s) in guild #{guild_id}\n")
          Enum.each(rooms, &link(&1, guild_id, channels, opts))
          Mix.shell().info("\nDone. Walk into a room to try it.")
      end
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  # --- steps ------------------------------------------------------------------

  defp link(zone, guild_id, channels, opts) do
    wanted = channel_name(zone)

    case Enum.find(channels, &(String.downcase(&1.name) == wanted)) do
      nil -> create_and_bind(zone, guild_id, wanted, opts)
      channel -> bind(zone, guild_id, channel, opts, "reused ##{channel.name}")
    end
  end

  defp create_and_bind(zone, guild_id, name, opts) do
    if opts[:dry_run] do
      Mix.shell().info("  #{zone.name}: would create ##{name}")
    else
      case Client.create_voice_channel(guild_id, name, user_limit: zone.capacity) do
        {:ok, channel} ->
          bind(zone, guild_id, channel, opts, "created ##{channel.name}")

        {:error, :missing_permission} ->
          Mix.shell().error("  #{zone.name}: the bot needs Manage Channels to create ##{name}")

        {:error, reason} ->
          Mix.shell().error("  #{zone.name}: could not create ##{name} — #{inspect(reason)}")
      end
    end
  end

  defp bind(zone, guild_id, channel, opts, note) do
    if opts[:dry_run] do
      Mix.shell().info("  #{zone.name}: would bind to ##{channel.name}")
    else
      case Worlds.bind_discord_channel(
             zone,
             %{
               discord_guild_id: guild_id,
               discord_channel_id: channel.id,
               discord_channel_name: channel.name,
               auto_move: true
             },
             authorize?: false
           ) do
        {:ok, _} -> Mix.shell().info("  #{zone.name}: #{note}")
        {:error, error} -> Mix.shell().error("  #{zone.name}: #{Exception.message(error)}")
      end
    end
  end

  # --- resolution ---------------------------------------------------------------

  defp check_configured do
    if Client.configured?() do
      :ok
    else
      {:error, "No DISCORD_BOT_TOKEN. Put it in .env (see .env.example) and try again."}
    end
  end

  defp resolve_guild(opts) do
    case opts[:guild] || Application.get_env(:breakaway, :discord, [])[:guild_id] do
      nil -> {:error, "No guild. Pass --guild ID or set DISCORD_GUILD_ID in .env."}
      guild_id -> {:ok, to_string(guild_id)}
    end
  end

  defp resolve_space(opts) do
    result =
      if slug = opts[:space] do
        Worlds.space_by_slug(slug, authorize?: false)
      else
        with {:ok, [space | _]} <- Worlds.list_spaces(authorize?: false), do: {:ok, space}
      end

    case result do
      {:ok, space} -> {:ok, space}
      _ -> {:error, "No office found. Run `mix breakaway.seed` first."}
    end
  end

  # Meeting rooms only unless --all: binding the lounge means walking past the
  # couch drags you into a call.
  defp rooms(space, opts) do
    kinds = if opts[:all], do: [:meeting, :social, :focus], else: [:meeting]

    Worlds.list_zones!(query: [filter: [space_id: space.id]], authorize?: false)
    |> Enum.filter(&(&1.kind in kinds and is_nil(&1.discord_channel_id)))
    |> Enum.sort_by(& &1.name)
  end

  defp channel_name(zone), do: String.downcase(zone.slug)
end
