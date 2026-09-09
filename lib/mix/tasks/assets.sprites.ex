defmodule Mix.Tasks.Assets.Sprites do
  @shortdoc "Regenerates the 2D spritesheets and atlas manifest"
  @moduledoc """
  Runs the asset generators in `assets/gen`, writing PNGs and `atlas.json` into
  `priv/static/images`. Requires Node (no npm dependencies).

      mix assets.sprites
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    {output, status} =
      System.cmd("node", ["assets/gen/index.mjs"], stderr_to_stdout: true, cd: File.cwd!())

    Mix.shell().info(output)

    if status != 0 do
      Mix.raise("sprite generation failed (exit #{status})")
    end
  end
end
