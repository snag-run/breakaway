defmodule Breakaway.World.Supervisor do
  @moduledoc "Registry + dynamic supervisor for the per-space simulations."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Breakaway.World.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Breakaway.World.SpaceSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
