defmodule Breakaway.Worlds do
  @moduledoc """
  The office floor plan: spaces, the zones marked out on them, and the furniture.
  """
  use Ash.Domain, otp_app: :breakaway

  resources do
    resource Breakaway.Worlds.Space do
      define :list_spaces, action: :read
      define :get_space, action: :read, get_by: [:id]
      define :space_by_slug, action: :by_slug, args: [:slug]
      define :create_space, action: :create
    end

    resource Breakaway.Worlds.Zone do
      define :list_zones, action: :read
      define :get_zone, action: :read, get_by: [:id]
      define :create_zone, action: :create
      define :bind_discord_channel, action: :bind_discord_channel
      define :unbind_discord_channel, action: :unbind_discord_channel
    end

    resource Breakaway.Worlds.Prop do
      define :list_props, action: :read
      define :create_prop, action: :create
    end
  end
end
