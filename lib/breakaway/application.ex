defmodule Breakaway.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BreakawayWeb.Telemetry,
      Breakaway.Repo,
      {DNSCluster, query: Application.get_env(:breakaway, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Breakaway.PubSub},
      # Outbound Discord calls run here so a slow API never stalls a game tick.
      {Task.Supervisor, name: Breakaway.TaskSupervisor},
      # Per-space simulations live under here, started on demand.
      Breakaway.World.Supervisor,
      # Watches who is actually in a Discord call. Idles unless a bot is configured.
      Breakaway.Discord.VoiceTracker,
      # Start to serve requests, typically the last entry
      BreakawayWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :breakaway]}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Breakaway.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BreakawayWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
