defmodule Breakaway.Worlds.Prop do
  @moduledoc """
  A piece of furniture placed on the floor. `kind` is constrained to the props
  that actually exist in the generated spritesheet.
  """
  use Ash.Resource,
    otp_app: :breakaway,
    domain: Breakaway.Worlds,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "props"
    repo Breakaway.Repo

    references do
      reference :space, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]
    default_accept []

    create :create do
      accept [:space_id, :kind, :x, :y, :solid, :facing]
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

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: Breakaway.Worlds.Atlas.prop_names()
    end

    attribute :x, :integer, allow_nil?: false, public?: true
    attribute :y, :integer, allow_nil?: false, public?: true

    attribute :facing, :atom do
      allow_nil? false
      default :down
      public? true
      constraints one_of: [:up, :down, :left, :right]

      description """
      Which way the furniture is turned. For seats this is also the direction
      the person sitting on it looks, so a desk chair faces :up into the desk.
      """
    end

    attribute :solid, :boolean do
      allow_nil? false
      default true
      public? true
      description "Whether avatars collide with this prop's footprint."
    end
  end

  relationships do
    belongs_to :space, Breakaway.Worlds.Space, allow_nil?: false
  end
end
