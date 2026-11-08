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
# After that, `mix test` boots the repo and builds the schema as a host
# does: core's versioned migrations (`PhoenixKit.Migration.ensure_current/2`),
# then the chains of the modules this one's foreign keys point at (AI,
# comments, entities, staff), then this module's own chain
# (`PhoenixKitProjects.Migrations.Schema`, keyed on its current version).
# The Ecto sandbox handles isolation.

# Elixir 1.19's `mix test` compiles `test/support` (`elixirc_paths(:test)`)
# but does not load those modules before this file runs. They are loaded here
# from the compiled build — never `Code.require_file/2`'d again from source,
# which redefined each one (a "redefining module" warning per file per run).
for mod <- [
      PhoenixKitProjects.Test.Repo,
      PhoenixKitProjects.Test.SchemaMigration,
      PhoenixKitProjects.Test.Layouts,
      PhoenixKitProjects.Test.Hooks,
      PhoenixKitProjects.Test.Router,
      PhoenixKitProjects.Test.Endpoint,
      PhoenixKitProjects.ActivityLogAssertions,
      PhoenixKitProjects.DataCase,
      PhoenixKitProjects.LiveCase
    ],
    do: Code.ensure_loaded!(mod)

alias PhoenixKitProjects.Test.Repo, as: TestRepo

db_name =
  Application.get_env(:phoenix_kit_projects, TestRepo, [])[:database] ||
    "phoenix_kit_projects_test"

# The preflight ships in core and is used when the running core has it;
# otherwise this falls through to exactly the previous behaviour.
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
      The reason is printed above. Run: createdb #{db_name} && mix test.setup
    """)

    false
  else
    try do
      {:ok, _} = TestRepo.start_link()

      # Build the schema the way a host does: core's versioned migrations
      # first (`ensure_current/2` re-applies any newly shipped version on
      # every boot), then the chains of the modules whose tables this one's
      # foreign keys point at, then this module's own chain.
      PhoenixKit.Migration.ensure_current(TestRepo, log: false)

      # The tables other modules own (core 3.0 no longer creates them): their real
      # chains, in dependency order.
      for chain <- [
            PhoenixKitAI.Migrations,
            PhoenixKitComments.Migrations,
            PhoenixKitEntities.Migrations,
            PhoenixKitStaff.Migrations
          ],
          stmt <- chain.up_statements("public") do
        TestRepo.query!(stmt)
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

          Could not connect to test database — integration tests excluded.
          Run: createdb #{db_name} && mix test.setup
          Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""

          Could not connect to test database — integration tests excluded.
          Run: createdb #{db_name} && mix test.setup
          Error: #{inspect(reason)}
        """)

        false
    end
  end

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
