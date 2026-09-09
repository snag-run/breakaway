defmodule BreakawayWeb.PageController do
  use BreakawayWeb, :controller

  @doc """
  Readiness check for load balancers and deploy gates.

  Touches the database, because an app that cannot reach Postgres cannot serve
  anybody — reporting healthy in that state just routes traffic into errors.
  """
  def health(conn, _params) do
    case Ecto.Adapters.SQL.query(Breakaway.Repo, "SELECT 1", [], timeout: 2_000) do
      {:ok, _} -> send_resp(conn, 200, "ok")
      {:error, _} -> send_resp(conn, 503, "database unavailable")
    end
  rescue
    _ -> send_resp(conn, 503, "database unavailable")
  catch
    :exit, _ -> send_resp(conn, 503, "database unavailable")
  end

  def home(conn, _params) do
    # Signed-in users have no reason to see the marketing page.
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/office")
    else
      render(conn, :home, layout: false)
    end
  end
end
