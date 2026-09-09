defmodule Breakaway.World.Interactions do
  @moduledoc """
  What pressing `E` next to a piece of furniture does.

  The prompt is sent to the browser so the on-screen hint and the effect the
  server applies always come from the same table.
  """

  # kind => {prompt shown to the person walking past, activity it puts them in}
  # Seats additionally move the avatar onto the furniture and switch it to the
  # seated pose, so they are listed in @seats below.
  @table %{
    desk: {"Work at this desk", "Heads down"},
    desk_double: {"Work at this desk", "Heads down"},
    office_chair: {"Take a seat", "Sitting"},
    chair: {"Take a seat", "Sitting"},
    meeting_table: {"Join the table", "In a meeting"},
    whiteboard: {"Use the whiteboard", "At the whiteboard"},
    tv_screen: {"Watch the screen", "Watching a demo"},
    couch: {"Sit on the couch", "On the couch"},
    beanbag: {"Flop into the beanbag", "Lounging"},
    coffee_table: {"Put your feet up", "Lounging"},
    coffee_machine: {"Make a coffee", "Getting coffee"},
    water_cooler: {"Fill up a glass", "At the water cooler"},
    fridge: {"Raid the fridge", "Raiding the fridge"},
    bookshelf: {"Browse the shelf", "Reading"},
    printer: {"Use the printer", "Fighting the printer"},
    server_rack: {"Check the rack", "Fixing the servers"},
    arcade: {"Play the arcade", "Playing arcade"},
    plant_small: {"Water the plant", "Watering the plants"},
    plant_tall: {"Water the plant", "Watering the plants"}
  }

  # Furniture you sit on rather than just stand next to.
  @seats [:chair, :office_chair, :couch, :beanbag]

  @doc """
  Whether using this puts the avatar *on* the furniture.

  Seats snap the avatar to the middle of the prop and face it toward the
  camera, matching how the seat sprites are drawn.
  """
  def seat?(kind), do: kind in @seats

  @doc "Which way you face once seated. Every seat sprite has its back to the top."
  def seated_facing, do: :down

  @doc "How close (in tiles, centre to centre) you must be to use something."
  def reach, do: 1.7

  def interactable?(kind), do: Map.has_key?(@table, kind)

  @doc "The activity this prop puts you in, or nil if it isn't interactive."
  def activity(kind) do
    case Map.fetch(@table, kind) do
      {:ok, {_prompt, activity}} -> activity
      :error -> nil
    end
  end

  @doc "Prompts keyed by prop kind, for the browser's `E` hint."
  def prompts, do: Map.new(@table, fn {kind, {prompt, _}} -> {kind, prompt} end)
end
