# Two nodes, one floor.
#
# Checks the claim that a space has exactly one simulation across the cluster,
# and that a node which is not running a floor does not think it is (which is
# what keeps Discord polling from being duplicated).
#
#     mix breakaway.seed
#     elixir --sname breakaway_main --cookie verify -S mix run scripts/verify_cluster.exs
#
alias Breakaway.{World, Worlds}

space = Worlds.space_by_slug!("hq", authorize?: false)
IO.puts("this node: #{Node.self()}")

host = Node.self() |> Atom.to_string() |> String.split("@") |> List.last() |> String.to_charlist()

{:ok, peer, peer_node} =
  :peer.start_link(%{
    name: :breakaway_peer,
    host: host,
    longnames: false,
    connection: :standard_io,
    args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
  })

:ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
:peer.call(peer, Application, :put_all_env, [[breakaway: Application.get_all_env(:breakaway)]])
{:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:ecto_sql])
{:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:postgrex])

# Hang the peer's supervision under kernel_sup: Supervisor.start_link would be
# linked to the transient RPC process and die the moment the call returns.
{:ok, _} =
  :peer.call(peer, :supervisor, :start_child, [
    :kernel_sup,
    %{
      id: :breakaway_root,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [[Breakaway.Repo, Breakaway.World.Supervisor], [strategy: :one_for_one, name: :peer_root]]}
    }
  ])

true = Node.connect(peer_node)
IO.puts("peer node: #{peer_node}, connected: #{peer_node in Node.list()}")
# :global needs a moment to sync its name table after a node joins.
Process.sleep(500)

{:ok, here} = World.ensure_started(space.id)
IO.puts("started here      -> #{inspect(here)} on #{node(here)}")

{:ok, there} = :peer.call(peer, World, :ensure_started, [space.id])
IO.puts("peer asked for it -> #{inspect(there)} on #{node(there)}")

IO.puts("")

if here == there do
  IO.puts("PASS: both nodes share one simulation")
else
  IO.puts("FAIL: two simulations for the same floor")
end

# The peer can drive the shared world across the node boundary.
peer_local = :peer.call(peer, World, :running_spaces, [])
IO.puts("floors running on the peer itself: #{inspect(peer_local)} (expected [])")

snapshot = :peer.call(peer, World, :snapshot, [space.id])
IO.puts("peer can read the shared floor: #{inspect(Map.keys(snapshot))}")

:peer.stop(peer)
