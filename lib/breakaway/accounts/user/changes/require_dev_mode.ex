defmodule Breakaway.Accounts.User.Changes.RequireDevMode do
  @moduledoc """
  Hard stop on the dev-only sign-in path.

  The controller that uses it is compiled out of production routes, but this
  refuses at the domain level too so the action can never mint an account on a
  real deployment even if something calls it directly.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Application.get_env(:breakaway, :dev_routes) do
      changeset
    else
      Ash.Changeset.add_error(changeset,
        field: :discord_id,
        message: "dev sign-in is only available when :dev_routes is enabled"
      )
    end
  end
end
