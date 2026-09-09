defmodule Breakaway.Worlds.AtlasTest do
  @moduledoc """
  The atlas is generated from the spritesheets, so these tests are really
  guarding that the art and the domain agree about what exists.
  """
  use ExUnit.Case, async: true

  alias Breakaway.Worlds.Atlas

  test "tile ids round-trip through names" do
    for name <- Atlas.tile_names() do
      assert is_integer(Atlas.tile_id(name))
      assert Atlas.tile_id(name) == Atlas.tile_id(String.to_existing_atom(name))
    end
  end

  test "walls and water block movement, floors do not" do
    for solid <- [:wall_front, :wall_window, :wall_top, :glass_front, :glass_top, :water] do
      assert Atlas.solid?(Atlas.tile_id(solid)), "#{solid} should be solid"
    end

    for open <- [:concrete, :floor_wood, :carpet_teal, :kitchen_tile, :grass, :door_mat] do
      refute Atlas.solid?(Atlas.tile_id(open)), "#{open} should be walkable"
    end
  end

  test "every prop has a positive footprint" do
    for kind <- Atlas.prop_names() do
      %{w: w, h: h} = Atlas.prop_meta(kind)
      assert w > 0 and h > 0
      assert w <= 2 and h <= 2, "#{kind} is larger than one spritesheet cell"
    end
  end

  test "there is at least one avatar palette" do
    assert Atlas.palette_count() > 0
    assert Atlas.tile_size() == 32
  end
end
