defmodule Breakaway.Worlds.Atlas do
  @moduledoc """
  Compile-time view of `priv/static/images/atlas.json`.

  The asset generator (`mix assets.sprites`) writes that file, so tile ids,
  collision flags and prop footprints can never drift from the spritesheets the
  browser is drawing. Regenerating assets triggers a recompile of this module.
  """

  @atlas_path Path.join(:code.priv_dir(:breakaway), "static/images/atlas.json")
  @external_resource @atlas_path

  @atlas @atlas_path |> File.read!() |> Jason.decode!()

  @tile_names @atlas["tiles"]["names"]
  @tile_index Map.new(Enum.with_index(@tile_names), fn {n, i} -> {String.to_atom(n), i} end)
  @solid_names Enum.map(@atlas["tiles"]["solid"], &String.to_atom/1)
  @solid_ids MapSet.new(@solid_names, &Map.fetch!(@tile_index, &1))
  @tile_size @atlas["tiles"]["size"]

  @prop_names Enum.map(@atlas["props"]["names"], &String.to_atom/1)
  @prop_meta Map.new(@atlas["props"]["meta"], fn {name, meta} ->
               {String.to_atom(name), %{index: meta["index"], w: meta["w"], h: meta["h"]}}
             end)

  @palette_count length(@atlas["avatars"]["palettes"])

  @doc "Pixel size of one tile."
  def tile_size, do: @tile_size

  @doc "All tile names, in spritesheet order."
  def tile_names, do: @tile_names

  @doc "Numeric id for a tile name, as stored in `Space.ground`."
  def tile_id(name) when is_atom(name), do: Map.fetch!(@tile_index, name)
  def tile_id(name) when is_binary(name), do: tile_id(String.to_existing_atom(name))

  @doc "Whether a tile id blocks movement."
  def solid?(id) when is_integer(id), do: MapSet.member?(@solid_ids, id)

  @doc "Every solid tile id."
  def solid_ids, do: @solid_ids

  @doc "Placeable prop names — the allowed values of `Prop.kind`."
  def prop_names, do: @prop_names

  @doc "Footprint of a prop in tiles, e.g. `%{w: 2, h: 1}`."
  def prop_meta(kind) when is_atom(kind), do: Map.fetch!(@prop_meta, kind)

  @doc "How many avatar colourways the spritesheet contains."
  def palette_count, do: @palette_count
end
