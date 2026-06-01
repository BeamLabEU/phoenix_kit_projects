defmodule PhoenixKitProjects.MixProject do
  use Mix.Project

  @version "0.7.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_projects"

  def project do
    [
      app: :phoenix_kit_projects,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "Projects module for PhoenixKit — projects, reusable tasks, assignments, and dependencies.",
      package: package(),
      dialyzer: [
        plt_add_apps: [:phoenix_kit, :phoenix_kit_staff],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      name: "PhoenixKitProjects",
      source_url: @source_url,
      docs: docs(),
      test_coverage: [
        ignore_modules: [
          ~r/^PhoenixKitProjects\.Test\./,
          PhoenixKitProjects.DataCase,
          PhoenixKitProjects.LiveCase,
          PhoenixKitProjects.ActivityLogAssertions
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :phoenix_kit, :phoenix_kit_staff]]
  end

  def cli do
    [preferred_envs: ["test.setup": :test, "test.reset": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "format",
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        "quality.ci"
      ],
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitProjects.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitProjects.Test.Repo",
        "test.setup"
      ]
    ]
  end

  defp deps do
    [
      # 1.7.128 is the floor — that's the release that ships the sub-project
      # (`child_project_uuid` on `phoenix_kit_project_assignments`, core V127)
      # and project-assignee (`assigned_team/department/person_uuid` on
      # `phoenix_kit_projects`, core V128) schema this module's sub-projects +
      # assignee features require. It also carries the V125 workflow-status
      # schema (`phoenix_kit_project_statuses` + `status_entity_uuid` /
      # `current_status_slug` / `settings` / `external_id`) for
      # `PhoenixKitProjects.Statuses`, and the 1.7.117 floor for the
      # AI-translation delegation in `TranslateResourceWorker`.
      {:phoenix_kit, "~> 1.7.128"},
      {:phoenix_kit_staff, "~> 0.1"},
      {:phoenix_kit_comments, "~> 0.2"},

      # Optional: the entities module is the source/catalog for project
      # workflow statuses. `optional: true` keeps it out of host closures
      # (PhoenixKitProjects.Statuses degrades gracefully when it's absent —
      # mirrors the AI-translation pattern) while making it loadable in this
      # package's own compile + test build.
      {:phoenix_kit_entities, "~> 0.2", optional: true},

      # Hard dep: assignment/task schemas reference PhoenixKitStaff.Schemas.*
      # for polymorphic assignee FKs (team / department / person).
      {:phoenix_live_view, "~> 1.1"},
      {:ecto_sql, "~> 3.13"},
      # Already transitive via :phoenix_kit, but pinned explicitly here so
      # `mix gettext.extract` / `mix gettext.merge` run against this app's
      # own `PhoenixKitProjects.Gettext` backend (call sites for project-
      # domain strings; common strings still resolve via core's backend).
      {:gettext, "~> 0.26 or ~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # `Phoenix.LiveViewTest` parses HTML via `lazy_html` for `element/2`,
      # `render(view) =~ "..."`, etc. Test-only.
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [main: "PhoenixKitProjects", source_ref: "v#{@version}"]
  end
end
