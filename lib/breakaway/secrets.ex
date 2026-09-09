defmodule Breakaway.Secrets do
  @moduledoc """
  Resolves runtime secrets for Ash Authentication.

  Everything here comes from application env, which `config/runtime.exs` fills
  from the environment so no credential is ever committed.
  """
  use AshAuthentication.Secret

  def secret_for([:authentication, :tokens, :signing_secret], Breakaway.Accounts.User, _, _) do
    Application.fetch_env(:breakaway, :token_signing_secret)
  end

  def secret_for([:authentication, :strategies, :discord, :client_id], _, _, _),
    do: fetch_discord(:client_id)

  def secret_for([:authentication, :strategies, :discord, :client_secret], _, _, _),
    do: fetch_discord(:client_secret)

  def secret_for([:authentication, :strategies, :discord, :redirect_uri], _, _, _),
    do: fetch_discord(:redirect_uri)

  defp fetch_discord(key) do
    case Application.get_env(:breakaway, :discord, [])[key] do
      nil -> :error
      value -> {:ok, value}
    end
  end
end
