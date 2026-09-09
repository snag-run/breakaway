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
  def move(space_id, user_id, vec), do: safely(fn -> SpaceServer.set_input(space_id, user_id, vec) end)

  def set_status(space_id, user_id, text),
    do: safely(fn -> SpaceServer.set_status(space_id, user_id, text) end)

  def snapshot(space_id), do: safely(fn -> SpaceServer.snapshot(space_id) end)

  def zone_occupancy(space_id) do
    case safely(fn -> SpaceServer.zone_occupancy(space_id) end) do
      {:error, :not_running} -> %{}
      other -> other
    end
  end

  def topic(space_id), do: SpaceServer.topic(space_id)

  def subscribe(space_id), do: Phoenix.PubSub.subscribe(Breakaway.PubSub, topic(space_id))

  def ensure_started(space_id) do
    case Registry.lookup(Breakaway.World.Registry, space_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
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
