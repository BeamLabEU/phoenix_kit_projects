import Config

# Integration tests run against a real PostgreSQL database. Create it with:
#   createdb phoenix_kit_projects_test
config :phoenix_kit_projects, ecto_repos: [PhoenixKitProjects.Test.Repo]

config :phoenix_kit_projects, PhoenixKitProjects.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "phoenix_kit_projects_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  priv: "test/support/postgres"

# Wire repo for PhoenixKit.RepoHelper — without this, context-layer DB calls crash.
config :phoenix_kit, repo: PhoenixKitProjects.Test.Repo

config :logger, level: :warning
