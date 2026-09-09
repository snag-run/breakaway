defmodule Breakaway.Accounts.UserIdentity do
  @moduledoc """
  Stores the Discord `iss`/`sub` pair behind each sign-in.

  Ash Authentication uses this to match a returning user by the only claim that
  is stable and unique, rather than by email address.
  """
  use Ash.Resource,
    otp_app: :breakaway,
    domain: Breakaway.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.UserIdentity]

  user_identity do
    user_resource Breakaway.Accounts.User
  end

  postgres do
    table "user_identities"
    repo Breakaway.Repo
  end
end
