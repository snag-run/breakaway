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

   Then **Save Changes** — it has no effect until you do. Copy the **Client ID**
   and **Client Secret**.

   Ignore the *OAuth2 URL Generator* scopes on that page: they only build an
   invite link. The scopes the app asks for at sign-in (`identify email guilds`)
   are sent by the app itself, in `Breakaway.Accounts.User`.

3. **Bot → Reset Token**, copy the token.

4. Invite the bot to your server with scope `bot`:

   ```
   https://discord.com/oauth2/authorize?client_id=YOUR_CLIENT_ID&scope=bot&permissions=17826832
   ```

   | Permission | Bit | Why |
   | --- | --- | --- |
   | View Channels | 1024 | see the voice channels to bind them |
   | Connect | 1048576 | see below |
   | Manage Channels | 16 | let the setup task create the rooms |
   | Move Members | 16777216 | the actual feature |

   Discord's docs say Move Members "allows for moving of members between voice
   channels" and don't say whether Connect on the target channel is also
   needed. Including it costs nothing — the bot never joins voice — and avoids a
   confusing 403 on channels with restricted permissions. Minimal set without
   it, and without channel creation: `permissions=16778240`.

5. Copy `.env.example` to `.env` and fill it in. `config/dev.exs` reads `.env`
   on boot, so `mix phx.server` picks it up — anything already exported in your
   shell wins. `.env` is gitignored; never commit it. Leave a key blank and it
   counts as unset, so the optional ones can stay empty.

   If you use [direnv](https://direnv.net), the committed `.envrc` loads `.env`
   into your shell too, so one-off `mix` tasks and `psql` see the credentials
   without `mix phx.server` in the picture. Run `direnv allow` once — and again
   after editing `.envrc` itself, though not after editing `.env`.

6. Wire the rooms up:

   ```bash
   mix breakaway.discord.setup --dry-run   # see what it would do
   mix breakaway.discord.setup
   ```

   For every meeting room that isn't linked, it reuses a voice channel whose
   name already matches and creates one if there isn't. Rooms already bound are
   left alone, so it's safe to re-run after adding a room. Pass `--all` to
   include the lounge, kitchen and focus pods — off by default, because binding
   the lounge means walking past the couch drags you into a call.

   It also sorts out the lobby channel and prints the `DISCORD_LOBBY_CHANNEL_ID`
   line to paste into `.env` — that's what returns people to a lobby when they
   walk out of a room. It reuses `#lobby` or `#general` if you already have one,
   and only creates `#lobby` when neither exists. Pass `--no-lobby` to skip it,
   or set the variable yourself. The channel is deliberately not bound to any
   zone: `auto_move` on the commons would drag anyone crossing the floor into a
   call.

   And it makes a permanent invite to the server, anchored on the lobby, and
   prints `DISCORD_INVITE_URL` — set that and the sign-in page offers a "join
   the server first" link to anyone who is not a member yet. `--no-invite`
   skips it. The bot needs **Create Instant Invite** for this one.

   New channels land at the server root. Pass `--category Breakaway` to group
   them under a category of that name instead, reusing one that already exists.

   ```bash
   mix breakaway.discord.setup --category Breakaway --all
   ```

   Or do it by hand: sign in and open **Discord** in the sidebar.

### What actually happens when you walk into a room

The simulation emits a zone transition, and `Breakaway.Discord.VoiceSync`
decides what it means. The Discord call runs on a supervised task so a slow API
never stalls the game tick.

Discord **cannot pull somebody into a call who isn't already connected to
voice** — there's no API for it. So the first hop is always manual: you get a
"join" link, and from then on the server can move you between rooms freely.
That's a platform limitation, not a missing feature.

Leaving a room only moves you if `DISCORD_LOBBY_CHANNEL_ID` is set — step 6
above prints it for you. Without it you stay in the call, on the assumption that
silently hanging up on somebody mid-sentence is worse than leaving them
connected.

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

Run `bin/migrate`, then `bin/seed`, then `bin/server`. The seed is not optional
on a fresh database — without it there is no floor to walk on and `/office` has
nothing to render. Both are idempotent: re-running updates the map and furniture
and leaves the Discord channel bindings on the zones intact, so they belong in a
deploy step rather than a one-off runbook.

`GET /health` checks the database and answers 503 if it cannot be reached, so a
load balancer never routes traffic to a node that can only serve errors.

### On Fly.io

`fly.toml` is committed and holds the shape of the deploy: the release command,
the health check, and the VM size. `rel/env.sh.eex` handles the rest — it names
the node for distributed Erlang and exports `DNS_CLUSTER_QUERY` and
`ECTO_IPV6`, so two machines cluster instead of each running their own copy of
the office. Prefer `fly deploy` over `fly launch`; launch rewrites both.

The database is Neon rather than a Fly cluster. `config/runtime.exs` sets
`ssl: true` because Neon refuses plaintext connections outright — the failure is
`connection is insecure (try using \`sslmode=require\`)` during the release
command, before a single migration runs.

```bash
fly apps create breakaway

# DATABASE_URL from Neon. Use the direct endpoint, not the -pooler one.
# SECRET_KEY_BASE and TOKEN_SIGNING_SECRET are generated straight into Fly, so
# they are never printed or stored here.
fly secrets set \
  DATABASE_URL="postgres://..." \
  SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  TOKEN_SIGNING_SECRET="$(mix phx.gen.secret)"

# Reuse the Discord credentials in .env without opening the file. REDIRECT_URI
# is excluded on purpose: the local one points at localhost, and a secret would
# override the correct value in fly.toml.
grep -E '^DISCORD_' .env | grep -v '^DISCORD_REDIRECT_URI=' | fly secrets import

fly deploy
```

`TOKEN_SIGNING_SECRET` is the one `fly launch` will not set for you — it knows
Phoenix's `SECRET_KEY_BASE` but nothing about AshAuthentication's, and
`runtime.exs` raises on it, so the release command fails identically to a
missing database.

#### A custom domain

```bash
fly ips list                      # note the v4 and v6 addresses
fly certs add breakaway.town
fly certs show breakaway.town     # watch it go Ready
```

Point the apex at both addresses at your registrar — an `A` record at the IPv4
and an `AAAA` at the IPv6. A shared IPv4 is fine here; every request arrives over
HTTPS with SNI, which is what Fly needs to tell apps apart on a shared address.
The certificate cannot be issued until those records resolve, so add them first
and expect `fly certs show` to sit pending for a few minutes.

For `www` as well, a `CNAME` to `breakaway.fly.dev` plus its own
`fly certs add www.breakaway.town`.

Then the hostname has to agree in three places, or sign-in breaks at the Discord
callback rather than in your logs:

- `PHX_HOST` and `DISCORD_REDIRECT_URI` in `fly.toml`.
- No `DISCORD_REDIRECT_URI` secret shadowing it — `fly secrets unset
  DISCORD_REDIRECT_URI` if `.env` put one there, since secrets beat `[env]`.
- The redirect registered on the Discord application's OAuth2 page, character
  for character, with **Save Changes** pressed.

#### Seeding without a deploy

`config/dev.exs` points at `DATABASE_URL` when one is set, so the production
database can be migrated and seeded from a local BEAM:

```bash
DATABASE_URL="postgres://..." mix ecto.migrate
DATABASE_URL="postgres://..." mix breakaway.seed
```

Pass it inline rather than exporting it — every `mix` command would follow it,
including the destructive ones.

## Tests

```bash
mix test
```

Discord is never called over the network; `Req.Test` stubs it, and the tests
cover the cases that matter in practice — someone not connected to voice, a bot
missing the Move Members permission, and auto-move turned off.
