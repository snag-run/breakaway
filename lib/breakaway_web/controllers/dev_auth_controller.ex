defmodule BreakawayWeb.DevAuthController do
  @moduledoc """
  Signs in a throwaway local user so the office can be explored without setting
  up a Discord application. Only routed when `:dev_routes` is enabled.

      /dev/sign-in-as/ada

  Open several in different browser profiles to see multiple avatars at once.
  """
  use BreakawayWeb, :controller

  def create(conn, %{"handle" => handle}) do
    handle = handle |> to_string() |> String.slice(0, 32)

    params = %{
      handle: handle,
      display_name: String.capitalize(handle),
      avatar_palette: :erlang.phash2(handle, Breakaway.Worlds.Atlas.palette_count())
    }

    case Ash.create(Breakaway.Accounts.User, params,
           action: :register_dev_user,
           authorize?: false
         ) do
      {:ok, user} ->
        conn
        |> AshAuthentication.Phoenix.Plug.store_in_session(user)
        |> put_flash(:info, "Signed in locally as #{user.display_name}")
        |> redirect(to: ~p"/office")

      {:error, error} ->
        conn
        |> put_flash(:error, "Dev sign-in failed: #{Exception.message(error)}")
        |> redirect(to: ~p"/")
    end
  end
end
