# Test helper for PhoenixKitProjects.
#
# Level 1: Unit tests (schemas, changesets, pure functions) always run.
# Level 2: Integration tests (tagged `:integration` via PhoenixKitProjects.DataCase)
#          require PostgreSQL — automatically excluded when the database
#          is unavailable.
#
# First-time setup:
#
#   createdb phoenix_kit_projects_test
#
# After that, `mix test` boots the repo, runs core's versioned migrations
# via `PhoenixKit.Migration.ensure_current/2` (V40 extensions +
# uuid_generate_v7, V03 settings, V90 activities, V100 staff tables,
# V101 projects tables, V112 projects.archived_at + visible partial
# index), and lets the Ecto sandbox handle isolation. No module-owned DDL.

# Elixir 1.19 quirk — see `phoenix_kit_locations` test_helper for context.
support_dir = Path.expand("support", __DIR__)

[
  "test_repo.ex",
  "schema_migration.ex",
  "test_layouts.ex",
  "hooks.ex",
  "test_router.ex",
  "test_endpoint.ex",
  "activity_log_assertions.ex",
  "data_case.ex",
  "live_case.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

alias PhoenixKitProjects.Test.Repo, as: TestRepo

db_name =
  Application.get_env(:phoenix_kit_projects, TestRepo, [])[:database] ||
    "phoenix_kit_projects_test"

# The preflight ships in core, and this module's core floor (`~> 2.0`)
# predates it — so it is used when the running core has it, and otherwise
# this falls through to exactly the previous behaviour.
db_check =
  if Code.ensure_loaded?(PhoenixKit.TestSupport.PostgresPreflight) do
    # One classified connection attempt, with the repo's OWN credentials and
    # transport, before anything starts the pool.
    #
    # This replaces a `psql -lqt` listing. That check asked the wrong question:
    # it ran as the shell's user over a unix socket, so it reported "the
    # database is there" and said nothing about whether the CONFIGURED role
    # could reach it over TCP. When it could not, the answer arrived minutes
    # later as a pool checkout timeout that reads like a flaky test.
    case PhoenixKit.TestSupport.PostgresPreflight.check(
           Application.get_env(:phoenix_kit_projects, PhoenixKitProjects.Test.Repo, [])
         ) do
      :ok ->
        :exists

      {:error, _reason, message} ->
        IO.puts(:stderr, "\n" <> message)
        :not_found
    end
  else
    :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""

      Cannot reach test database "#{db_name}" — integration tests excluded.
       The reason is printed above. && mix test.setup
    """)

    false
  else
    try do
      {:ok, _} = TestRepo.start_link()

      # Build the schema directly from core's versioned migrations — same
      # call the host app makes in production. Replaces the hand-rolled
      # `test/support/postgres/migrations/` shim, which was a transition
      # state from when V100 (staff) and V101 (projects) weren't yet in
      # core's published Hex release. `ensure_current/2` (core 1.7.105+
      # / phoenix_kit#515) re-applies any newly-shipped Vxxx migrations
      # on every boot. See `dev_docs/migration_cleanup.md` for the
      # staleness story.
      PhoenixKit.Migration.ensure_current(TestRepo, log: false)

      # Then entities' chain, because the Data project extension reads and
      # writes entity records through `PhoenixKitEntities`' own schemas. Its
      # V1 is adoptive, so this is a no-op today — it is here so it stays
      # one. The moment entities ships a version that adds a column, a
      # harness that never ran its chain fails on an `undefined_column`
      # raised from a query this module did not write. Guarded because
      # entities is an optional dep: absent, its schemas are unreachable
      # anyway, so there is nothing to migrate.
      if Code.ensure_loaded?(PhoenixKitEntities.Migrations) do
        for stmt <- PhoenixKitEntities.Migrations.up_statements("public") do
          TestRepo.query!(stmt)
        end
      end

      # Then run the module-owned chain (V1 baselines the core-built shape,
      # V2+ add hub-rework tables). The migration is keyed on the CHAIN
      # version, not a fixed number — when Schema.@current_version bumps,
      # the new version number is unapplied and the (idempotent, full-chain)
      # up re-runs. A fixed `{0, Module}` would go silently stale, the exact
      # trap core's ensure_current/2 moduledoc warns about. Running on every
      # boot also proves the baseline's idempotency against tables core's
      # chain already created.
      Ecto.Migrator.run(
        TestRepo,
        [
          {PhoenixKitProjects.Migrations.Schema.current_version(),
           PhoenixKitProjects.Test.SchemaMigration}
        ],
        :up,
        all: true,
        log: false
      )

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
    rescue
      e ->
        IO.puts("""

          Could not connect to test database — integration tests excluded.          The reason is printed above. && mix test.setup
          Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""

          Could not connect to test database — integration tests excluded.          The reason is printed above. && mix test.setup
          Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_projects, :test_repo_available, repo_available)

# Minimal PhoenixKit services needed by the context layer.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])

# `Staff.register_placeholder/1` (called by Projects via cross-module
# create flows) goes through `PhoenixKit.Users.Auth.register_user/2`,
# which calls the Hammer-backed rate limiter. Mirrors core's
# `phoenix_kit/test/test_helper.exs:69`.
{:ok, _pid} = PhoenixKit.Users.RateLimiter.Backend.start_link([])

# Force PhoenixKit's URL prefix cache to "/" for tests so `Paths.index()`
# etc. produce paths the test router can match. Admin paths always get
# the default locale ("en") prefix, so our router scope is `/en/admin/projects`.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

# Start the test Endpoint so Phoenix.LiveViewTest can drive our LiveViews
# via `live/2` with real URLs. Runs with `server: false`, so no port is
# opened. Only starts when the test DB is available.
if repo_available do
  {:ok, _} = PhoenixKitProjects.Test.Endpoint.start_link()
end

exclude = if repo_available, do: [], else: [:integration]
ExUnit.start(exclude: exclude)
