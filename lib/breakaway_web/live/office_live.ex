defmodule BreakawayWeb.OfficeLive do
  @moduledoc """
  The office floor.

  The canvas is driven entirely by `push_event/3` — avatar ticks never touch
  assigns, so a 20Hz simulation does not cause 20 diffs a second. Sidebar state
  is only re-assigned when the roster actually changes.
  """
  use BreakawayWeb, :live_view

  alias Breakaway.Accounts
  alias Breakaway.World
  alias Breakaway.Worlds

  @max_messages 60

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user

    case load_space(params) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "No office has been set up yet. Run `mix breakaway.seed`.")
         |> assign(
           space: nil,
           zones: [],
           zone_index: %{},
           messages: [],
           roster: [],
           roster_key: nil,
           voice: nil,
           my_zone: nil,
           editing_profile?: false,
           page_title: "Breakaway"
         )}

      space ->
        zones = list_zones(space)

        socket =
          assign(socket,
            space: space,
            zones: zones,
            zone_index: Map.new(zones, &{&1.slug, &1}),
            messages: [],
            roster: [],
            roster_key: nil,
            my_zone: nil,
            voice: nil,
            editing_profile?: false,
            page_title: space.name
          )

        if connected?(socket) do
          World.subscribe(space.id)
          Phoenix.PubSub.subscribe(Breakaway.PubSub, "user:#{user.id}")

          case World.join(space.id, user) do
            {:ok, state} ->
              {:ok,
               socket
               |> push_map(space, zones)
               |> push_event("office:tick", state)
               |> refresh_roster(state.avatars)}

            {:error, reason} ->
              {:ok, put_flash(socket, :error, "Could not enter the office: #{inspect(reason)}")}
          end
        else
          {:ok, socket}
        end
    end
  end

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns do
      %{space: %{id: id}, current_user: %{id: user_id}} -> World.leave(id, user_id)
      _ -> :ok
    end

    :ok
  end

  # --- events from the browser ------------------------------------------------

  @impl true
  def handle_event("move", %{"dx" => dx, "dy" => dy}, socket) do
    World.move(socket.assigns.space.id, socket.assigns.current_user.id, {dx, dy})
    {:noreply, socket}
  end

  def handle_event("say", %{"text" => text}, socket) do
    text = text |> to_string() |> String.trim() |> String.slice(0, 240)

    if text == "" do
      {:noreply, socket}
    else
      user = socket.assigns.current_user
      World.mark_active(socket.assigns.space.id, user.id)

      Phoenix.PubSub.broadcast(
        Breakaway.PubSub,
        World.topic(socket.assigns.space.id),
        {:said,
         %{
           id: user.id,
           name: user.display_name,
           text: text,
           zone: socket.assigns.my_zone,
           at: DateTime.utc_now()
         }}
      )

      {:noreply, push_event(socket, "office:sent", %{})}
    end
  end

  def handle_event("walk_to", %{"x" => x, "y" => y}, socket) do
    World.walk_to(socket.assigns.space.id, socket.assigns.current_user.id, {x, y})
    {:noreply, socket}
  end

  def handle_event("interact", _params, socket) do
    World.interact(socket.assigns.space.id, socket.assigns.current_user.id)
    {:noreply, socket}
  end

  def handle_event("edit_profile", _params, socket),
    do: {:noreply, assign(socket, :editing_profile?, true)}

  def handle_event("cancel_profile", _params, socket),
    do: {:noreply, assign(socket, :editing_profile?, false)}

  def handle_event("save_profile", params, socket) do
    attrs = %{
      display_name: params["display_name"] |> to_string() |> String.trim() |> String.slice(0, 40),
      status_message:
        params["status_message"] |> to_string() |> String.trim() |> String.slice(0, 60),
      avatar_palette: to_palette(params["avatar_palette"])
    }

    # An empty status means "clear it", not "set it to the empty string".
    attrs = if attrs.status_message == "", do: %{attrs | status_message: nil}, else: attrs

    case Accounts.update_profile(socket.assigns.current_user, attrs,
           actor: socket.assigns.current_user
         ) do
      {:ok, user} ->
        World.refresh_profile(socket.assigns.space.id, user)

        {:noreply, assign(socket, current_user: user, editing_profile?: false)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{Exception.message(error)}")}
    end
  end

  def handle_event("dismiss_voice", _params, socket), do: {:noreply, assign(socket, :voice, nil)}

  # --- events from the simulation ---------------------------------------------

  @impl true
  def handle_info({:tick, state}, socket) do
    {:noreply,
     socket
     |> push_event("office:tick", state)
     |> refresh_roster(state.avatars)}
  end

  # You only hear what's said in the room you're standing in — walking out of a
  # meeting should end the conversation, not follow you across the floor.
  def handle_info({:said, message}, socket) do
    if message.zone == socket.assigns.my_zone do
      {:noreply,
       socket
       |> update(:messages, &Enum.take([message | &1], @max_messages))
       |> push_event("office:say", %{id: message.id, text: message.text})}
    else
      {:noreply, socket}
    end
  end

  # Outcome of a Discord voice move for *this* user.
  def handle_info({:voice, payload}, socket), do: {:noreply, assign(socket, :voice, payload)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- helpers ----------------------------------------------------------------

  defp load_space(%{"slug" => slug}),
    do: slug |> Worlds.space_by_slug(authorize?: false) |> ok_or_nil()

  defp load_space(_params) do
    case Worlds.list_spaces(authorize?: false) do
      {:ok, [space | _]} -> space
      _ -> nil
    end
  end

  defp ok_or_nil({:ok, value}), do: value
  defp ok_or_nil(_), do: nil

  defp list_zones(space) do
    case Worlds.list_zones(query: [filter: [space_id: space.id]], authorize?: false) do
      {:ok, zones} -> zones
      _ -> []
    end
  end

  defp push_map(socket, space, zones) do
    props =
      case Worlds.list_props(query: [filter: [space_id: space.id]], authorize?: false) do
        {:ok, props} -> Enum.map(props, &%{kind: &1.kind, x: &1.x, y: &1.y, facing: &1.facing})
        _ -> []
      end

    push_event(socket, "office:map", %{
      interactions: Breakaway.World.Interactions.prompts(),
      reach: Breakaway.World.Interactions.reach(),
      width: space.width,
      height: space.height,
      spawn_x: space.spawn_x,
      spawn_y: space.spawn_y,
      ground: space.ground,
      props: props,
      zones:
        Enum.map(
          zones,
          &%{
            slug: &1.slug,
            name: &1.name,
            kind: &1.kind,
            x: &1.x,
            y: &1.y,
            width: &1.width,
            height: &1.height,
            accent: &1.accent
          }
        )
    })
  end

  # Ticks arrive 20x a second; only touch assigns when the roster meaningfully
  # changed, so the sidebar isn't re-diffed on every step.
  defp refresh_roster(socket, avatars) do
    me = socket.assigns.current_user.id
    key = avatars |> Enum.map(&{&1.id, &1.z, &1.s, &1.away}) |> Enum.sort()

    if key == socket.assigns[:roster_key] do
      socket
    else
      roster =
        avatars
        |> Enum.map(
          &%{id: &1.id, name: &1.n, zone: &1.z, status: &1.s, palette: &1.p, away: &1.away}
        )
        |> Enum.sort_by(&{&1.zone || "~", String.downcase(&1.name)})

      my_zone = Enum.find_value(avatars, fn a -> if a.id == me, do: a.z end)

      assign(socket, roster: roster, roster_key: key, my_zone: my_zone)
    end
  end

  defp grouped_roster(roster, zones) do
    names = Map.new(zones, &{&1.slug, &1.name})

    roster
    |> Enum.group_by(& &1.zone)
    |> Enum.map(fn {slug, people} -> {slug, Map.get(names, slug, "On the floor"), people} end)
    |> Enum.sort_by(fn {slug, name, _} -> {slug == nil, name} end)
  end

  @doc """
  Keyboard reference. Rendered once and then owned by the client, so toggling it
  costs no round trip and the choice is remembered across visits.
  """
  def controls_overlay(assigns) do
    ~H"""
    <div id="controls" phx-hook="ControlsOverlay" phx-update="ignore" class="pointer-events-auto">
      <div
        data-role="panel"
        class="mb-2 w-64 rounded-xl bg-black/60 p-3.5 text-sm backdrop-blur"
      >
        <p class="mb-2.5 text-xs font-semibold uppercase tracking-wider text-zinc-400">
          Controls
        </p>

        <dl class="space-y-2">
          <div :for={{keys, action} <- controls()} class="flex items-baseline justify-between gap-3">
            <dt class="flex shrink-0 gap-1">
              <kbd
                :for={key <- keys}
                class="rounded border border-white/15 bg-white/10 px-1.5 py-0.5 font-mono text-[11px] leading-none text-zinc-200"
              >
                {key}
              </kbd>
            </dt>
            <dd class="text-right text-xs text-zinc-400">{action}</dd>
          </div>
        </dl>

        <p class="mt-3 border-t border-white/10 pt-2.5 text-xs text-zinc-500">
          Walk into a meeting room to join its Discord call.
        </p>
      </div>

      <button
        data-role="toggle"
        type="button"
        aria-expanded="true"
        aria-label="Toggle controls"
        class="ml-auto flex h-8 w-8 items-center justify-center rounded-full bg-black/60 text-sm font-semibold text-zinc-300 backdrop-blur hover:bg-black/75 hover:text-white"
      >
        ?
      </button>
    </div>
    """
  end

  defp controls do
    [
      {["W", "A", "S", "D"], "Walk"},
      {["↑", "←", "↓", "→"], "Walk"},
      {["Click"], "Walk to a spot"},
      {["E"], "Use what you're standing by"},
      {["Enter"], "Talk to the room"},
      {["Esc"], "Back to walking"},
      {["−", "+"], "Zoom out / in"},
      {["?"], "Hide this panel"}
    ]
  end

  # --- components -------------------------------------------------------------

  attr :voice, :any, default: nil

  @doc """
  Explains what Discord just did — or why it couldn't — after a zone change.
  """
  def voice_banner(assigns) do
    ~H"""
    <div :if={@voice} class="pointer-events-auto max-w-sm">
      <div class={[
        "flex items-start gap-3 rounded-xl px-3.5 py-2.5 text-sm shadow-lg backdrop-blur",
        voice_tone(@voice)
      ]}>
        <div class="min-w-0 flex-1">
          <p class="font-medium">{voice_title(@voice)}</p>
          <p class="mt-0.5 text-xs opacity-80">{voice_detail(@voice)}</p>

          <a
            :if={voice_url(@voice)}
            href={voice_url(@voice)}
            target="_blank"
            rel="noopener"
            class="mt-2 inline-block rounded-lg bg-white/15 px-2.5 py-1 text-xs font-semibold hover:bg-white/25"
          >
            Open in Discord
          </a>
        </div>

        <button
          phx-click="dismiss_voice"
          class="shrink-0 text-xs opacity-60 hover:opacity-100"
          aria-label="Dismiss"
        >
          ✕
        </button>
      </div>
    </div>
    """
  end

  defp voice_tone({:moved, _}), do: "bg-emerald-500/85 text-emerald-950"
  defp voice_tone({:returned_to_lobby, _}), do: "bg-emerald-500/85 text-emerald-950"
  defp voice_tone({:join_required, _, _}), do: "bg-amber-400/90 text-amber-950"
  defp voice_tone({:failed, _, _}), do: "bg-rose-500/85 text-rose-50"
  defp voice_tone(_), do: "bg-zinc-700/85 text-zinc-100"

  defp voice_title({:moved, zone}), do: "You joined #{zone.name}"
  defp voice_title({:returned_to_lobby, zone}), do: "You left #{zone.name}"
  defp voice_title({:join_required, zone, _}), do: "#{zone.name} is waiting"
  defp voice_title({:left_room, zone}), do: "You left #{zone.name}"
  defp voice_title({:failed, zone, _}), do: "Couldn't move you into #{zone.name}"
  defp voice_title({:unconfigured, zone}), do: "#{zone.name} isn't connected"

  defp voice_detail({:moved, zone}),
    do: "Discord moved you into #" <> (zone.discord_channel_name || "voice") <> "."

  defp voice_detail({:returned_to_lobby, _}), do: "Moved back to the lobby channel."

  defp voice_detail({:join_required, zone, _}),
    do:
      "Connect to voice once and we'll move you automatically after that. " <>
        "Channel: #" <> (zone.discord_channel_name || "voice")

  defp voice_detail({:left_room, _}),
    do: "You're still connected to the call — hang up in Discord when you're done."

  defp voice_detail({:failed, _, :missing_permission}),
    do: "The bot needs the Move Members permission in that server."

  defp voice_detail({:failed, _, :not_a_member}),
    do: "You're not a member of the linked Discord server."

  defp voice_detail({:failed, _, reason}), do: "Discord said: #{inspect(reason)}"

  defp voice_detail({:unconfigured, _}),
    do: "Set DISCORD_BOT_TOKEN and bind this room to a voice channel to enable calls."

  defp voice_url({:join_required, _zone, url}) when is_binary(url), do: url
  defp voice_url(_), do: nil

  defp linked_zone?(_index, nil), do: false

  defp linked_zone?(index, slug) do
    case Map.get(index, slug) do
      %{discord_channel_id: id} when is_binary(id) -> true
      _ -> false
    end
  end

  defp to_palette(value) do
    case Integer.parse(to_string(value)) do
      {n, _} -> rem(abs(n), Breakaway.Worlds.Atlas.palette_count())
      :error -> 0
    end
  end

  defp palettes, do: 0..(Breakaway.Worlds.Atlas.palette_count() - 1)

  # The avatar sheet is one row per direction, four directions per palette, with
  # the walk cycle across. This picks each palette's front-facing standing frame.
  defp palette_preview_offset(palette), do: palette * 4 * 40 * 2

  defp kind_label(:meeting), do: "Meeting room"
  defp kind_label(:focus), do: "Focus pods"
  defp kind_label(:social), do: "Social"
  defp kind_label(:lobby), do: "Commons"
  defp kind_label(_), do: ""
end
