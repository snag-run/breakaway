defmodule Breakaway.Accounts.UserTest do
  use Breakaway.DataCase

  alias Breakaway.Accounts.User

  @user_info %{
    "id" => "1080000000000000001",
    "username" => "ada",
    "global_name" => "Ada Lovelace",
    "avatar" => "a1b2c3",
    "email" => "ada@example.com",
    "verified" => true
  }

  @tokens %{"access_token" => "at-1", "refresh_token" => "rt-1", "expires_in" => 604_800}

  defp register(info \\ @user_info, tokens \\ @tokens) do
    Ash.create(User, %{user_info: info, oauth_tokens: tokens},
      action: :register_with_discord,
      authorize?: false
    )
  end

  test "a Discord payload becomes a user" do
    assert {:ok, user} = register()

    assert user.discord_id == "1080000000000000001"
    assert user.discord_username == "ada"
    assert user.display_name == "Ada Lovelace"

    assert user.discord_avatar ==
             "https://cdn.discordapp.com/avatars/1080000000000000001/a1b2c3.png"

    assert to_string(user.email) == "ada@example.com"
    assert user.discord_access_token == "at-1"
    assert user.discord_refresh_token == "rt-1"
    assert DateTime.compare(user.discord_token_expires_at, DateTime.utc_now()) == :gt
  end

  test "the username is used when Discord has no display name" do
    assert {:ok, user} = register(Map.delete(@user_info, "global_name"))
    assert user.display_name == "ada"
  end

  test "a user with no avatar set gets nil rather than a broken URL" do
    assert {:ok, user} = register(Map.put(@user_info, "avatar", nil))
    assert user.discord_avatar == nil
  end

  test "signing in again updates the same account rather than making a new one" do
    assert {:ok, first} = register()

    renamed = %{@user_info | "username" => "ada_l", "global_name" => "Ada L"}
    assert {:ok, second} = register(renamed, %{"access_token" => "at-2", "expires_in" => 100})

    assert first.id == second.id
    assert second.discord_username == "ada_l"
    assert second.display_name == "Ada L"
    assert second.discord_access_token == "at-2"

    assert {:ok, users} = Ash.read(User, authorize?: false)
    assert length(users) == 1
  end

  test "the identity is keyed on the Discord id, not the email address" do
    assert {:ok, user} = register()
    assert {:ok, user} = Ash.load(user, :identities, authorize?: false)

    assert [identity] = user.identities
    assert identity.uid == "1080000000000000001"
    assert identity.strategy == "discord"
  end

  test "someone else's account is not taken over by a matching email" do
    assert {:ok, ada} = register()

    other = %{@user_info | "id" => "1080000000000000002", "username" => "grace"}
    assert {:ok, grace} = register(other)

    refute ada.id == grace.id
  end

  test "the dev sign-in refuses when dev routes are disabled" do
    previous = Application.get_env(:breakaway, :dev_routes)
    Application.put_env(:breakaway, :dev_routes, false)
    on_exit(fn -> Application.put_env(:breakaway, :dev_routes, previous) end)

    assert {:error, error} =
             Ash.create(User, %{handle: "sneaky", display_name: "Sneaky"},
               action: :register_dev_user,
               authorize?: false
             )

    assert Exception.message(error) =~ "dev sign-in is only available"
  end
end
