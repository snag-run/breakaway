defmodule BreakawayWeb.PageControllerTest do
  use BreakawayWeb.ConnCase

  import Breakaway.Fixtures

  test "the landing page explains the app and offers Discord sign-in", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "A room your team can walk around in"
    assert html =~ "Sign in with Discord"
  end

  test "the health check reports ok while the database is reachable", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert response(conn, 200) == "ok"
  end

  test "someone already signed in goes straight to the office", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")

    assert redirected_to(conn) == ~p"/office"
  end
end
