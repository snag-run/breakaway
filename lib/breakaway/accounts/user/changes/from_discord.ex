defmodule Breakaway.Accounts.User.Changes.FromDiscord do
  @moduledoc """
  Maps a Discord `/users/@me` payload and its OAuth2 token response onto user
  attributes. Discord hands us string-keyed maps, so everything is read defensively.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    info = Ash.Changeset.get_argument(changeset, :user_info) || %{}
    tokens = Ash.Changeset.get_argument(changeset, :oauth_tokens) || %{}

    discord_id = get(info, "id") || get(info, "sub")
    username = get(info, "username") || get(info, "preferred_username")

    changeset
    |> Ash.Changeset.force_change_attribute(:discord_id, to_string(discord_id))
    |> Ash.Changeset.force_change_attribute(:discord_username, username)
    |> Ash.Changeset.force_change_attribute(
      :display_name,
      get(info, "global_name") || get(info, "nickname") || username
    )
    |> Ash.Changeset.force_change_attribute(
      :discord_avatar,
      avatar_url(discord_id, get(info, "avatar"))
    )
    |> put_if_present(:email, get(info, "email"))
    |> Ash.Changeset.force_change_attribute(:discord_access_token, get(tokens, "access_token"))
    |> Ash.Changeset.force_change_attribute(:discord_refresh_token, get(tokens, "refresh_token"))
    |> Ash.Changeset.force_change_attribute(
      :discord_token_expires_at,
      expires_at(get(tokens, "expires_in"))
    )
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
  defp get(_, _), do: nil

  # A user with no custom avatar has a nil hash; Discord serves them a default.
  defp avatar_url(_id, nil), do: nil
  defp avatar_url(id, hash), do: "https://cdn.discordapp.com/avatars/#{id}/#{hash}.png"

  defp put_if_present(changeset, _attr, nil), do: changeset

  defp put_if_present(changeset, attr, value),
    do: Ash.Changeset.force_change_attribute(changeset, attr, value)

  defp expires_at(nil), do: nil

  defp expires_at(seconds) when is_integer(seconds),
    do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp expires_at(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {n, _} -> expires_at(n)
      :error -> nil
    end
  end
end
