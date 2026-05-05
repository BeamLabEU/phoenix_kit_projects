defmodule PhoenixKitProjects.MixProject do
  use Mix.Project

  @version "0.1.1"
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
      dialyzer: [plt_add_apps: [:phoenix_kit, :phoenix_kit_staff]],
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
      precommit: ["compile", "quality"],
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
      {:phoenix_kit, "~> 1.7"},
      # Hard dep: assignment/task schemas reference PhoenixKitStaff.Schemas.*
      # for polymorphic assignee FKs (team / department / person).
      {:phoenix_kit_staff, "~> 0.1"},
      {:phoenix_live_view, "~> 1.1"},
      {:ecto_sql, "~> 3.13"},
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
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [main: "PhoenixKitProjects", source_ref: "v#{@version}"]
  end
end
