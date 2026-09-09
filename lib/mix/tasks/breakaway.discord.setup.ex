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
      mix breakaway.discord.setup --all              # social and focus rooms too
      mix breakaway.discord.setup --category Breakaway   # group them in a category
      mix breakaway.discord.setup --no-lobby         # skip the lobby channel

  It also sorts out the lobby channel people are returned to when they walk out
  of a meeting room, and prints the `DISCORD_LOBBY_CHANNEL_ID` line to paste
  into `.env`. It reuses `#lobby` or `#general` if the server has one and only
  creates `#lobby` when neither exists. Pass `--no-lobby` to skip that, or set
  the variable yourself.

  Needs `DISCORD_BOT_TOKEN` and a guild the bot is in, holding **Manage
  Channels** (to create) and **Move Members** (to move people once it's live).
  """
  use Mix.Task

  alias Breakaway.Discord.Client
  alias Breakaway.Worlds

  @requirements ["app.start"]

  @switches [
    guild: :string,
    dry_run: :boolean,
    all: :boolean,
    space: :string,
    category: :string,
    lobby: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: @switches)

    with :ok <- check_configured(),
         {:ok, guild_id} <- resolve_guild(opts),
         {:ok, space} <- resolve_space(opts),
         {:ok, channels} <- Client.list_voice_channels(guild_id),
         {:ok, parent_id} <- resolve_category(guild_id, opts) do
      zones = zones(space)

      case rooms(zones, opts) do
        [] ->
          Mix.shell().info("Nothing to link — every room already has a channel.")

        rooms ->
          Mix.shell().info("Linking #{length(rooms)} room(s) in guild #{guild_id}\n")
          Enum.each(rooms, &link(&1, guild_id, channels, parent_id, opts))
      end

      lobby(guild_id, channels, parent_id, opts)

      Mix.shell().info("\nDone. Walk into a room to try it.")
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  # --- steps ------------------------------------------------------------------

  defp link(zone, guild_id, channels, parent_id, opts) do
    wanted = channel_name(zone)

    case find_channel(channels, wanted) do
      nil -> create_and_bind(zone, guild_id, wanted, parent_id, opts)
      channel -> bind(zone, guild_id, channel, opts, "reused ##{channel.name}")
    end
  end

  defp create_and_bind(zone, guild_id, name, parent_id, opts) do
    if opts[:dry_run] do
      Mix.shell().info("  #{zone.name}: would create ##{name}")
    else
      case Client.create_voice_channel(guild_id, name,
             user_limit: zone.capacity,
             parent_id: parent_id
           ) do
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

  # --- the lobby ----------------------------------------------------------------

  # Names a server plausibly already uses for the channel people sit in between
  # meetings, most specific first. Reusing one beats adding a near-duplicate to
  # a server that already has somewhere obvious to go.
  @lobby_names ["lobby", "general"]

  # Where people are put back when they leave a meeting room. Deliberately not
  # bound to any zone: `auto_move` on the commons would drag anyone crossing the
  # floor into a call. All the app wants is the id, in `.env`.
  defp lobby(guild_id, channels, parent_id, opts) do
    cond do
      not Keyword.get(opts, :lobby, true) ->
        :ok

      configured_lobby_id() ->
        Mix.shell().info("\nLobby: already set by DISCORD_LOBBY_CHANNEL_ID.")

      true ->
        case Enum.find_value(@lobby_names, &find_channel(channels, &1)) do
          nil -> create_lobby(guild_id, hd(@lobby_names), parent_id, opts)
          channel -> announce_lobby(channel, "reused ##{channel.name}")
        end
    end
  end

  defp create_lobby(guild_id, name, parent_id, opts) do
    if opts[:dry_run] do
      Mix.shell().info("\nLobby: would create ##{name}")
    else
      # No user_limit — a full lobby would reject the move back out of a room.
      case Client.create_voice_channel(guild_id, name, parent_id: parent_id) do
        {:ok, channel} ->
          announce_lobby(channel, "created ##{channel.name}")

        {:error, :missing_permission} ->
          Mix.shell().error("\nLobby: the bot needs Manage Channels to create ##{name}")

        {:error, reason} ->
          Mix.shell().error("\nLobby: could not create ##{name} — #{inspect(reason)}")
      end
    end
  end

  defp announce_lobby(channel, note) do
    Mix.shell().info("""

    Lobby: #{note}
      Put this in .env, so leaving a room returns people to it:
      DISCORD_LOBBY_CHANNEL_ID=#{channel.id}\
    """)
  end

  defp configured_lobby_id, do: present(discord_config()[:lobby_channel_id])

  # --- resolution ---------------------------------------------------------------

  defp check_configured do
    if Client.configured?() do
      :ok
    else
      {:error, "No DISCORD_BOT_TOKEN. Put it in .env (see .env.example) and try again."}
    end
  end

  defp resolve_guild(opts) do
    case present(opts[:guild]) || present(discord_config()[:guild_id]) do
      nil -> {:error, "No guild. Pass --guild ID or set DISCORD_GUILD_ID in .env."}
      guild_id -> {:ok, to_string(guild_id)}
    end
  end

  defp discord_config, do: Application.get_env(:breakaway, :discord, [])

  # A key left blank in .env reaches us as "", which is truthy. Absent is
  # absent however it was spelled.
  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value

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

  # Channels land at the guild root unless asked to group them.
  defp resolve_category(guild_id, opts) do
    case opts[:category] do
      nil ->
        {:ok, nil}

      name ->
        case Client.list_categories(guild_id) do
          {:ok, categories} ->
            case Enum.find(categories, &(String.downcase(&1.name) == String.downcase(name))) do
              nil ->
                create_category(guild_id, name, opts)

              category ->
                Mix.shell().info("Grouping under the existing #{category.name} category.\n")
                {:ok, category.id}
            end

          {:error, reason} ->
            {:error, "Could not list the guild's categories — #{inspect(reason)}"}
        end
    end
  end

  defp create_category(guild_id, name, opts) do
    if opts[:dry_run] do
      Mix.shell().info("Would create the #{name} category.\n")
      {:ok, nil}
    else
      case Client.create_category(guild_id, name) do
        {:ok, category} ->
          Mix.shell().info("Created the #{category.name} category.\n")
          {:ok, category.id}

        {:error, :missing_permission} ->
          {:error, "The bot needs Manage Channels to create the #{name} category."}

        {:error, reason} ->
          {:error, "Could not create the #{name} category — #{inspect(reason)}"}
      end
    end
  end

  defp zones(space) do
    Worlds.list_zones!(query: [filter: [space_id: space.id]], authorize?: false)
  end

  # Meeting rooms only unless --all: binding the lounge means walking past the
  # couch drags you into a call.
  defp rooms(zones, opts) do
    kinds = if opts[:all], do: [:meeting, :social, :focus], else: [:meeting]

    zones
    |> Enum.filter(&(&1.kind in kinds and is_nil(&1.discord_channel_id)))
    |> Enum.sort_by(& &1.name)
  end

  defp find_channel(channels, name), do: Enum.find(channels, &(String.downcase(&1.name) == name))

  defp channel_name(zone), do: String.downcase(zone.slug)
end
