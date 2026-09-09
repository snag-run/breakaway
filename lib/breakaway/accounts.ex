defmodule Breakaway.Accounts do
  use Ash.Domain,
    otp_app: :breakaway

  resources do
    resource Breakaway.Accounts.Token
    resource Breakaway.Accounts.User
    resource Breakaway.Accounts.UserIdentity
  end
end
