defmodule PhoenixKitProjects.MixProject do
  use Mix.Project

  @version "0.13.0"
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
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
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

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit or
  # PHOENIX_KIT_AI_PATH=../phoenix_kit_ai. Unset => the published pin, so
  # mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # 1.7.130 is the core floor. It still satisfies the earlier floors:
      # V127 `child_project_uuid` +
      # V128 project-assignee columns shipped in 1.7.128, V125 for the
      # workflow-status schema `PhoenixKitProjects.Statuses` requires.
      pk_dep(:phoenix_kit, "~> 1.7.130"),
      # PhoenixKitAI owns the generic AI-translation pipeline this module's
      # `AITranslatable` / `AITranslateBinding` code plugs into. 0.4 is the
      # floor — that's the release that actually ships the AI-translation move
      # (`PhoenixKitAI.{Translatable,Translations,Components.AITranslate.*}`);
      # 0.3.0 predates it and won't compile against this module.
      pk_dep(:phoenix_kit_ai, "~> 0.4"),
      pk_dep(:phoenix_kit_staff, "~> 0.1"),
      pk_dep(:phoenix_kit_comments, "~> 0.2"),

      # Optional: the entities module is the source/catalog for project
      # workflow statuses. `optional: true` keeps it out of host closures
      # (PhoenixKitProjects.Statuses degrades gracefully when it's absent —
      # mirrors the AI-translation pattern) while making it loadable in this
      # package's own compile + test build.
      pk_dep(:phoenix_kit_entities, "~> 0.2", optional: true),

      # Hard dep: assignment/task schemas reference PhoenixKitStaff.Schemas.*
      # for polymorphic assignee FKs (team / department / person).
      {:phoenix_live_view, "~> 1.1"},
      {:ecto_sql, "~> 3.13"},
      # Gantt/waterfall chart for the project timeline view. 0.3 is the floor —
      # its connector router lays out any task order followably (so the timeline
      # no longer pre-sorts by dependency). Hex by default (publish-safe); export
      # PHOENIX_LIVE_GANTT_PATH=../phoenix_live_gantt to build against a local checkout.
      pk_dep(:phoenix_live_gantt, "~> 0.3"),
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
