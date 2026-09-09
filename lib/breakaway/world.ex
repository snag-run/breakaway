defmodule Breakaway.World do
  @moduledoc """
  Entry point to the live office.

  One `SpaceServer` runs per space, started on demand the first time somebody
  walks in and supervised for the lifetime of the node.
  """

  alias Breakaway.World.SpaceServer

  @doc "Start (or find) the server for a space and put `user` on the floor."
  def join(space_id, user, pid \\ self()) do
    with {:ok, _} <- ensure_started(space_id) do
      SpaceServer.join(space_id, user, pid)
    end
  end

  def leave(space_id, user_id), do: safely(fn -> SpaceServer.leave(space_id, user_id) end)

  @doc "Record a movement intent — a vector of -1..1 on each axis."
  def move(space_id, user_id, vec),
    do: safely(fn -> SpaceServer.set_input(space_id, user_id, vec) end)

  @doc "Walk to a point on the floor, routing around furniture and walls."
  def walk_to(space_id, user_id, point),
    do: safely(fn -> SpaceServer.walk_to(space_id, user_id, point) end)

  @doc "Use the nearest piece of furniture, or stop using the current one."
  def interact(space_id, user_id), do: safely(fn -> SpaceServer.interact(space_id, user_id) end)

  @doc "Note that someone did something deliberate, so they are not idle."
  def mark_active(space_id, user_id),
    do: safely(fn -> SpaceServer.mark_active(space_id, user_id) end)

  @doc "Push a changed display name, colour or status onto the floor."
  def refresh_profile(space_id, user),
    do: safely(fn -> SpaceServer.refresh_profile(space_id, user) end)

  def snapshot(space_id), do: safely(fn -> SpaceServer.snapshot(space_id) end)

  def zone_occupancy(space_id) do
    case safely(fn -> SpaceServer.zone_occupancy(space_id) end) do
      {:error, :not_running} -> %{}
      other -> other
    end
  end

  @doc """
  Space ids whose simulation is running *on this node*.

  Deliberately node-local: each floor runs in one place, so having every node
  poll only its own floors means no duplicated Discord traffic.
  """
  def running_spaces do
    Registry.select(Breakaway.World.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc "Who this floor needs Discord voice state for."
  def voice_targets(space_id), do: safely(fn -> SpaceServer.voice_targets(space_id) end)

  @doc "Hand back what Discord says about who is in a call."
  def apply_voice_states(space_id, states),
    do: safely(fn -> SpaceServer.apply_voice_states(space_id, states) end)

  def topic(space_id), do: SpaceServer.topic(space_id)

  def subscribe(space_id), do: Phoenix.PubSub.subscribe(Breakaway.PubSub, topic(space_id))

  @doc """
  Find the simulation for a floor anywhere in the cluster, starting it here if
  nobody is running it yet.

  Two nodes can race; `:global` names make the loser's start fail with
  `{:already_started, pid}`, and it simply uses the winner's process.
  """
  def ensure_started(space_id) do
    case SpaceServer.whereis(space_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case DynamicSupervisor.start_child(
               Breakaway.World.SpaceSupervisor,
               {SpaceServer, space_id: space_id}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  # A space server can legitimately be down (nobody inside); callers should not
  # crash a LiveView over it.
  defp safely(fun) do
    fun.()
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {:normal, _} -> {:error, :not_running}
  end
end
