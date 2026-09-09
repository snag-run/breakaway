defmodule BreakawayWeb.PageController do
  use BreakawayWeb, :controller

  def home(conn, _params) do
    # Signed-in users have no reason to see the marketing page.
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/office")
    else
      render(conn, :home, layout: false)
    end
  end
end
