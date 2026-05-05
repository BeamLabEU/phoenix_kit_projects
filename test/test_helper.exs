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
# V101 projects tables), and lets the Ecto sandbox handle isolation.
# No module-owned DDL.

# Elixir 1.19 quirk — see `phoenix_kit_locations` test_helper for context.
support_dir = Path.expand("support", __DIR__)

[
  "test_repo.ex",
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

db_check =
  try do
    case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
      {output, 0} ->
        exists =
          output
          |> String.split("\n")
          |> Enum.any?(fn line ->
            line |> String.split("|") |> List.first("") |> String.trim() == db_name
          end)

        if exists, do: :exists, else: :not_found

      _ ->
        :try_connect
    end
  rescue
    # `psql` binary not installed — fall through to the connect-attempt
    # path. Honors the AGENTS.md contract that `mix test` never
    # hard-fails on a missing DB.
    ErlangError -> :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""

      Test database "#{db_name}" not found — integration tests excluded.
      Run: createdb #{db_name} && mix test.setup
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
