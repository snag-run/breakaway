defmodule Breakaway.Accounts do
  use Ash.Domain,
    otp_app: :breakaway

  resources do
    resource Breakaway.Accounts.Token

    resource Breakaway.Accounts.User do
      define :update_profile, action: :update_profile
    end

    resource Breakaway.Accounts.UserIdentity
  end
end
