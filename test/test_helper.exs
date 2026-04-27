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
#   mix test.setup
#
# After that, `mix test` boots the repo and lets the Ecto sandbox handle
# isolation. The schema is built by
# `test/support/postgres/migrations/<timestamp>_setup_phoenix_kit.exs`,
# which calls `PhoenixKit.Migrations.up()` for V01..V96 prereqs and
# inlines the V100 (staff) + V101 (projects) DDL.

# Elixir 1.19 quirk — see `phoenix_kit_locations` test_helper for context.
Code.require_file("support/test_repo.ex", __DIR__)
Code.require_file("support/data_case.ex", __DIR__)

alias PhoenixKitProjects.Test.Repo, as: TestRepo

db_name =
  Application.get_env(:phoenix_kit_projects, TestRepo, [])[:database] ||
    "phoenix_kit_projects_test"

db_check =
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

exclude = if repo_available, do: [], else: [:integration]
ExUnit.start(exclude: exclude)
