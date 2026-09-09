defmodule Breakaway.Worlds.Zone do
  @moduledoc """
  A named rectangle on the floor — a meeting room, a focus pod, the lounge.

  A zone of kind `:meeting` is the bridge to Discord: bind it to a voice channel
  and walking inside puts you in that call.
  """
  use Ash.Resource,
    otp_app: :breakaway,
    domain: Breakaway.Worlds,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "zones"
    repo Breakaway.Repo

    references do
      reference :space, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]
    default_accept []

    create :create do
      accept [
        :space_id,
        :name,
        :slug,
        :kind,
        :x,
        :y,
        :width,
        :height,
        :capacity,
        :accent
      ]

      upsert? true
      upsert_identity :unique_slug_per_space
      upsert_fields [:name, :kind, :x, :y, :width, :height, :capacity, :accent]
    end

    update :bind_discord_channel do
      description "Point this zone at a Discord voice channel."
      accept [:discord_guild_id, :discord_channel_id, :discord_channel_name, :auto_move]
      require_atomic? false
    end

    update :unbind_discord_channel do
      accept []
      require_atomic? false

      change set_attribute(:discord_guild_id, nil)
      change set_attribute(:discord_channel_id, nil)
      change set_attribute(:discord_channel_name, nil)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    # The floor plan is seeded from code and the Discord bindings are made by
    # `mix breakaway.discord.setup`, both of which run as the operator with
    # `authorize?: false`. Nothing reached from a browser has any business
    # rewriting a zone, and "any signed-in user" was the same thing as "anyone
    # holding the server invite".
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :slug, :string, allow_nil?: false, public?: true

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:meeting, :focus, :social, :lobby]
      default :meeting
    end

    attribute :x, :integer, allow_nil?: false, public?: true
    attribute :y, :integer, allow_nil?: false, public?: true
    attribute :width, :integer, allow_nil?: false, public?: true
    attribute :height, :integer, allow_nil?: false, public?: true

    attribute :capacity, :integer, public?: true
    attribute :accent, :string, public?: true, default: "#6f8fd6"

    attribute :discord_guild_id, :string, public?: true
    attribute :discord_channel_id, :string, public?: true
    attribute :discord_channel_name, :string, public?: true

    attribute :auto_move, :boolean do
      allow_nil? false
      default true
      public? true
      description "Move members into the bound channel automatically on entry."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :space, Breakaway.Worlds.Space, allow_nil?: false
  end

  calculations do
    calculate :discord_linked?, :boolean, expr(not is_nil(discord_channel_id)) do
      public? true
    end
  end

  identities do
    identity :unique_slug_per_space, [:space_id, :slug]
  end
end
