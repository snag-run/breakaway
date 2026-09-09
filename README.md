# Breakaway

A 2D virtual coworking office. Everyone gets an avatar on a shared tile floor;
the meeting rooms are bound to Discord voice channels, so walking into a room
puts you in that call and walking out takes you back.

Built with Phoenix LiveView and [Ash](https://ash-hq.org). Movement is
simulated server-side and drawn on a canvas.

![the office](priv/static/images/tileset.png)

## Running it

You need Elixir 1.15+, Node (for the asset generator only), and PostgreSQL.

```bash
mix setup          # deps, database, migrations, assets, and the default office
mix phx.server
```

Then open <http://localhost:4000>.

**You don't need Discord to look around.** In development, visit
`/dev/sign-in-as/<name>` — e.g. <http://localhost:4000/dev/sign-in-as/ada> — to
get a local account. Open a second browser profile as another name to see two
avatars share the floor. This route is compiled out unless `:dev_routes` is
enabled, and the underlying action refuses to run without it.

### Controls

| Key | |
| --- | --- |
| `W` `A` `S` `D` / arrows | Walk |
| `E` | Use the furniture you're standing next to |
| `Enter` | Talk to the room |
| `Esc` | Back to walking |
| Click | Walk to a spot |
| `−` `+` | Zoom out / in |
| `?` | Show or hide the controls panel |

## Connecting Discord

Two separate things: an **OAuth app** so people can sign in, and a **bot** so
the server can move them between voice channels.

1. Create an application at
   <https://discord.com/developers/applications>.

2. **OAuth2 → Redirects**, add:

   ```
   http://localhost:4000/auth/user/discord/callback
   ```

   Copy the **Client ID** and **Client Secret**.

3. **Bot → Reset Token**, copy the token.

4. Invite the bot to your server. Under **OAuth2 → URL Generator** pick scope
   `bot` and the permissions **View Channels** and **Move Members**, or use:

   ```
   https://discord.com/oauth2/authorize?client_id=YOUR_CLIENT_ID&scope=bot&permissions=16778240
   ```

5. Copy `.env.example` to `.env`, fill it in, and restart the server.

6. Sign in, open **Discord** in the sidebar, and bind each meeting room to a
   voice channel.

### What actually happens when you walk into a room

The simulation emits a zone transition, and `Breakaway.Discord.VoiceSync`
decides what it means. The Discord call runs on a supervised task so a slow API
never stalls the game tick.

Discord **cannot pull somebody into a call who isn't already connected to
voice** — there's no API for it. So the first hop is always manual: you get a
"join" link, and from then on the server can move you between rooms freely.
That's a platform limitation, not a missing feature.

Leaving a room only moves you if `DISCORD_LOBBY_CHANNEL_ID` is set. Without it
you stay in the call, on the assumption that silently hanging up on somebody
mid-sentence is worse than leaving them connected.

### ...and the other direction

`Breakaway.Discord.VoiceTracker` watches who is genuinely connected, so the
office and the call agree. Avatars carry a dot when they are really in a call
(red when muted), the roster counts how many of a room's occupants are on the
call, and **joining a bound voice channel from Discord walks your avatar into
that room**.

It polls, because Discord only serves a member's voice state over REST one
member at a time — the bulk view arrives over the gateway. It asks about the
people who are currently on a floor, in parallel, every few seconds
(`:voice_poll_ms`), which at team scale is well inside Discord's budget and
avoids running a gateway connection with its reconnect and resume machinery. A
lookup that fails is dropped rather than being treated as "they hung up".

If you outgrow that, the replacement is a gateway client publishing the same
`{:voice_states, space_id, map}` — nothing downstream would change.

## How it fits together

```
Browser (canvas + LiveView hook)
   │  movement intent, "use this", chat
   ▼
OfficeLive ──────────► SpaceServer (one per floor, 20Hz)
   ▲  push_event            │  authoritative position + collision
   │  positions, ticks      │
   │                        ▼  zone entered / left
   └──────────────────  VoiceSync ──► Discord REST
```

- **`Breakaway.Worlds`** — `Space` (the tile grid), `Zone` (rooms, optionally
  bound to a voice channel), `Prop` (furniture). The default floor plan is
  generated in `Breakaway.Worlds.DefaultOffice`.
- **`Breakaway.World.SpaceServer`** — one GenServer per floor. Clients send a
  direction vector, never a position, so a tampered client can't walk through
  walls or teleport into a meeting.
- **`Breakaway.Accounts`** — Discord-only sign-in. A `UserIdentity` record keys
  the account on Discord's `id` claim rather than on email, so a matching email
  address can never take over somebody else's account.

## Running more than one node

A floor's simulation is registered through `:global`, so exactly one runs
cluster-wide no matter how many nodes are up. Nodes race to start it; the loser
gets `{:already_started, pid}` and uses the winner. Calls route across nodes,
and PubSub is already distributed, so it does not matter which node a browser
happens to be connected to.

Each node also registers its own floors in a local `Registry`, purely so the
voice poller can iterate "the floors running here" — that is what stops two
nodes both polling Discord for the same people.

Check it yourself against two real nodes:

```bash
elixir --sname breakaway_main --cookie verify -S mix run scripts/verify_cluster.exs
```

The caveat: a floor lives in memory on one node. If that node dies, the floor is
gone and the next person to walk in starts a fresh one — everyone's position
resets to where it was last written, which happens when people leave cleanly
rather than continuously. That is a fine trade for an office and a bad one for a
game with stakes.

## The 2D assets

The spritesheets are generated, not drawn by hand — `assets/gen` contains a
small dependency-free PNG encoder and a pixel-art surface:

```bash
mix assets.sprites
```

This writes `tileset.png`, `furniture.png`, `avatars.png` (four directions, a
four-frame walk cycle, six colourways) and `atlas.json` into
`priv/static/images`.

`atlas.json` is the single source of truth. `Breakaway.Worlds.Atlas` reads it at
compile time, so tile ids, which tiles are solid, and how many tiles each piece
of furniture occupies cannot drift from the art. Editing a sprite and
regenerating updates the collision map with it.

To change the look, edit `assets/gen/tiles.mjs`, `furniture.mjs` or
`avatars.mjs` and re-run the task.

## Deploying

```bash
mix assets.deploy
MIX_ENV=prod mix release
```

or build the generated `Dockerfile`. Then set, at minimum:

| | |
| --- | --- |
| `DATABASE_URL` | `ecto://user:pass@host/breakaway` |
| `SECRET_KEY_BASE` | `mix phx.gen.secret` |
| `TOKEN_SIGNING_SECRET` | `mix phx.gen.secret` |
| `PHX_HOST` | the public hostname |
| `PHX_SERVER` | `true` |
| `DISCORD_*` | see `.env.example` |
| `DNS_CLUSTER_QUERY` | optional, to find sibling nodes |

Run migrations with `bin/migrate`, then `bin/server`. `GET /health` checks the
database and answers 503 if it cannot be reached, so a load balancer never
routes traffic to a node that can only serve errors.

Two things to get right:

- **`DISCORD_REDIRECT_URI` must exactly match** a redirect registered on the
  Discord application — `https://your-host/auth/user/discord/callback`. A
  mismatch fails at the callback with a Discord error, not in your logs.
- The dev sign-in is compiled out: `/dev/sign-in-as/...` returns 404 when
  `:dev_routes` is off, and the action behind it refuses independently. Both
  hold in a release built with `MIX_ENV=prod`.

## Tests

```bash
mix test
```

Discord is never called over the network; `Req.Test` stubs it, and the tests
cover the cases that matter in practice — someone not connected to voice, a bot
missing the Move Members permission, and auto-move turned off.
