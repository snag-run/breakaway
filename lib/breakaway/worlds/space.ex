defmodule Breakaway.Worlds.Space do
  @moduledoc """
  One office floor: a tile grid plus the zones and props placed on it.

  `ground` is a row-major array of tile ids (see `Breakaway.Worlds.Atlas`) of
  length `width * height`.
  """
  use Ash.Resource,
    otp_app: :breakaway,
    domain: Breakaway.Worlds,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "spaces"
    repo Breakaway.Repo
  end

  actions do
    defaults [:read, :destroy]
    default_accept []

    read :by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    create :create do
      accept [:name, :slug, :width, :height, :spawn_x, :spawn_y, :ground]
      upsert? true
      upsert_identity :unique_slug
      upsert_fields [:name, :width, :height, :spawn_x, :spawn_y, :ground]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :slug, :string, allow_nil?: false, public?: true

    attribute :width, :integer, allow_nil?: false, public?: true
    attribute :height, :integer, allow_nil?: false, public?: true

    attribute :spawn_x, :integer, allow_nil?: false, default: 1, public?: true
    attribute :spawn_y, :integer, allow_nil?: false, default: 1, public?: true

    attribute :ground, {:array, :integer} do
      allow_nil? false
      public? true
      description "Row-major tile ids, width * height entries."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :zones, Breakaway.Worlds.Zone
    has_many :props, Breakaway.Worlds.Prop
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
