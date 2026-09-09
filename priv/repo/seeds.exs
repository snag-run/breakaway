# Seeds the default office floor plan.
#
# Run with `mix run priv/repo/seeds.exs`, or via `mix setup`. Safe to re-run:
# the space and zones upsert on their slug and the furniture is replaced, while
# any Discord channel bindings on the zones are left alone.

space = Breakaway.Worlds.Seeder.seed_default_office!()

IO.puts("Seeded #{space.name} (#{space.width}x#{space.height})")
