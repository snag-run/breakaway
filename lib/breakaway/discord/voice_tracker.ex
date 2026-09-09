defmodule Breakaway.Discord.VoiceTracker do
  @moduledoc """
  Tells the office who is actually in a Discord call.

  Discord only exposes a member's voice state over REST one member at a time —
  the bulk view arrives over the gateway — so this polls the people who are
  currently on a floor rather than the whole guild. At team scale (tens of
  people, every few seconds) that is well inside Discord's budget, and it keeps
  the app free of a gateway connection and its reconnect/resume machinery.

  If this ever needs to scale past that, the replacement is a gateway client
  publishing the same `{:voice_states, space_id, map}` message; nothing
  downstream would change.

  Does nothing at all unless a bot token is configured.
  """
  use GenServer

  require Logger

  alias Breakaway.Discord.Client
  alias Breakaway.World

  @default_interval_ms 6_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Poll immediately instead of waiting for the next tick."
  def refresh, do: send(__MODULE__, :poll)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    if Client.configured?(), do: poll_all()
    schedule()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule, do: Process.send_after(self(), :poll, interval_ms())

  defp interval_ms,
    do: Application.get_env(:breakaway, :voice_poll_ms, @default_interval_ms)

  # --- polling ----------------------------------------------------------------

  defp poll_all do
    for space_id <- World.running_spaces() do
      case World.voice_targets(space_id) do
        {:error, _} -> :ok
        [] -> :ok
        targets -> poll_space(space_id, targets)
      end
    end
  end

  @doc """
  Looks up each person's connection and hands the result back to their floor.

  Exposed so tests can drive a single round without waiting on the timer.
  """
  def poll_space(space_id, targets) do
    states =
      targets
      # Discord only answers about one member at a time, so ask in parallel —
      # otherwise a floor of twenty is twenty round trips end to end.
      |> Task.async_stream(
        fn %{user_id: user_id, discord_id: discord_id, guild_id: guild_id} ->
          {user_id, lookup(guild_id, discord_id)}
        end,
        max_concurrency: 8,
        timeout: 10_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, result} -> [result]
        {:exit, _reason} -> []
      end)
      # A failed lookup is not the same as "not in a call" — leave what we
      # already believed rather than showing everyone as hung up.
      |> Enum.reject(fn {_user_id, result} -> result == :unknown end)
      |> Map.new()

    if states != %{}, do: World.apply_voice_states(space_id, states)
    states
  end

  defp lookup(guild_id, discord_id) do
    case Client.connection(guild_id, discord_id) do
      {:ok, connection} ->
        connection

      {:error, reason} ->
        Logger.debug("voice lookup failed for #{discord_id}: #{inspect(reason)}")
        :unknown
    end
  end
end
