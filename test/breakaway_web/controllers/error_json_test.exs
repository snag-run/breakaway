defmodule BreakawayWeb.ErrorJSONTest do
  use BreakawayWeb.ConnCase, async: true

  test "renders 404" do
    assert BreakawayWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert BreakawayWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
