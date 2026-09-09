defmodule Breakaway.Accounts.User do
  @moduledoc """
  A person in the office.

  Identity comes entirely from Discord: the same account that signs in is the
  account we move between voice channels, so `discord_id` is the natural key.
  """
  use Ash.Resource,
    otp_app: :breakaway,
    domain: Breakaway.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  authentication do
    tokens do
      enabled? true
      token_resource Breakaway.Accounts.Token
      signing_secret Breakaway.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      # Discord is the only way in. `guilds` lets us show the user which of
      # their servers this office can be wired up to.
      oauth2 :discord do
        client_id Breakaway.Secrets
        client_secret Breakaway.Secrets
        redirect_uri Breakaway.Secrets
        base_url "https://discord.com/api/v10"
        authorize_url "https://discord.com/oauth2/authorize"
        token_url "https://discord.com/api/v10/oauth2/token"
        user_url "https://discord.com/api/v10/users/@me"
        authorization_params scope: "identify email guilds"
        auth_method :client_secret_post
        registration_enabled? true
        identity_resource Breakaway.Accounts.UserIdentity
        # We never match an account by email — the upsert key is discord_id —
        # so an unverified Discord email can never take over another account.
        trust_email_verified? true
        register_action_name :register_with_discord
        icon :discord
      end
    end
  end

  postgres do
    table "users"
    repo Breakaway.Repo
  end

  actions do
    defaults [:read]
    default_accept []

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    read :get_by_discord_id do
      argument :discord_id, :string, allow_nil?: false
      get? true
      filter expr(discord_id == ^arg(:discord_id))
    end

    create :register_with_discord do
      description "Upsert the user behind a completed Discord OAuth2 exchange."
      argument :user_info, :map, allow_nil?: false
      argument :oauth_tokens, :map, allow_nil?: false

      upsert? true
      upsert_identity :unique_discord_id

      upsert_fields [
        :email,
        :discord_username,
        :discord_avatar,
        :display_name,
        :discord_access_token,
        :discord_refresh_token,
        :discord_token_expires_at
      ]

      change Breakaway.Accounts.User.Changes.FromDiscord
      change AshAuthentication.Strategy.OAuth2.IdentityChange
      change AshAuthentication.GenerateTokenChange
    end

    create :register_dev_user do
      description """
      Local development only: creates a signed-in user without a round trip to
      Discord, so the office can be run without OAuth credentials. Refuses
      unless `:dev_routes` is enabled.
      """

      accept [:display_name, :avatar_palette]
      argument :handle, :string, allow_nil?: false

      upsert? true
      upsert_identity :unique_discord_id
      upsert_fields [:display_name, :avatar_palette]

      change Breakaway.Accounts.User.Changes.RequireDevMode

      change fn changeset, _ctx ->
        handle = Ash.Changeset.get_argument(changeset, :handle)

        changeset
        |> Ash.Changeset.force_change_attribute(:discord_id, "dev-" <> handle)
        |> Ash.Changeset.force_change_attribute(:discord_username, handle)
      end

      # This action isn't owned by a strategy, so name the one whose token
      # settings should apply.
      change {AshAuthentication.GenerateTokenChange, strategy_name: :discord}
    end

    update :update_profile do
      description "Change how you look and what you're called in the office."
      accept [:display_name, :avatar_palette, :status_message]
      require_atomic? false
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    # Everyone in the office can see everyone else — it is a shared room.
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:update_profile) do
      authorize_if expr(id == ^actor(:id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :discord_id, :string do
      allow_nil? false
      public? true
      description "Discord snowflake — also the id used for voice channel moves."
    end

    attribute :discord_username, :string, allow_nil?: false, public?: true
    attribute :display_name, :string, allow_nil?: false, public?: true
    attribute :discord_avatar, :string, public?: true
    attribute :email, :ci_string, public?: true
    attribute :status_message, :string, public?: true

    attribute :avatar_palette, :integer do
      allow_nil? false
      default 0
      public? true
      description "Index into the palettes baked into avatars.png."
    end

    attribute :discord_access_token, :string, sensitive?: true
    attribute :discord_refresh_token, :string, sensitive?: true
    attribute :discord_token_expires_at, :utc_datetime_usec, sensitive?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :identities, Breakaway.Accounts.UserIdentity do
      destination_attribute :user_id
    end
  end

  identities do
    identity :unique_discord_id, [:discord_id]
  end
end
