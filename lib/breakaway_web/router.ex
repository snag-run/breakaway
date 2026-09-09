defmodule BreakawayWeb.Router do
  use BreakawayWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BreakawayWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
  end

  # No pipeline: a health check should not need a session, and should stay up
  # even if something in the browser stack is unhappy.
  scope "/", BreakawayWeb do
    get "/health", PageController, :health
  end

  scope "/", BreakawayWeb do
    pipe_through :browser

    get "/", PageController, :home

    ash_authentication_live_session :office,
      on_mount: [{BreakawayWeb.LiveUserAuth, :live_user_required}] do
      live "/office", OfficeLive, :index
      live "/office/:slug", OfficeLive, :show
    end

    auth_routes AuthController, Breakaway.Accounts.User, path: "/auth"

    sign_out_route AuthController, "/sign-out",
      overrides: [BreakawayWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]

    # Discord is the only strategy, so there is no register/reset/confirm flow.
    sign_in_route auth_routes_prefix: "/auth",
                  on_mount: [{BreakawayWeb.LiveUserAuth, :live_no_user}],
                  overrides: [
                    BreakawayWeb.AuthOverrides,
                    AshAuthentication.Phoenix.Overrides.Default
                  ]
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:breakaway, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev", BreakawayWeb do
      pipe_through :browser

      get "/sign-in-as/:handle", DevAuthController, :create
    end

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BreakawayWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
