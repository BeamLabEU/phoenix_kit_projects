defmodule PhoenixKitProjects.MixProject do
  use Mix.Project

  @version "0.21.2"
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
    # `:phoenix_kit_staff` is deliberately absent: it is an optional dep, and
    # naming it here makes the app fail to boot wherever it is not installed.
    [extra_applications: [:logger, :phoenix_kit]]
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

    cond do
      dropped_dep?(app) ->
        nil

      path = System.get_env(env_var) ->
        {app, [path: path, override: true] ++ opts}

      opts == [] ->
        {app, requirement}

      true ->
        {app, requirement, opts}
    end
  end

  # The staff-optional seam's compile gate, which until now did not exist.
  #
  # AGENTS.md, this file's own dep comment, `People`'s and the seam test's
  # docstrings all describe `WITHOUT_STAFF=1 mix deps.get && WITHOUT_STAFF=1
  # mix compile --warnings-as-errors` as the check that no stray
  # `PhoenixKitStaff.*` reference sneaks back in. Nothing read the variable,
  # so the "gate" compiled WITH staff installed and passed unconditionally —
  # which is how two direct references to the optional package's schemas
  # (`Grants`, `ProjectMembersLive`) got in and silently broke group grants
  # on staff-less installs. `optional: true` governs a CONSUMER's dependency
  # closure; it does not remove the dep from our own build.
  defp dropped_dep?(:phoenix_kit_staff),
    do: System.get_env("WITHOUT_STAFF") in ["1", "true"]

  defp dropped_dep?(_app), do: false

  defp deps do
    [
      # 1.7.231 is the core floor: that is the release shipping
      # `PhoenixKitWeb.Live.UrlState`, which `ProjectsLive`, `TasksLive` and
      # `TemplatesLive` all `use` — including the `mode: :history` option they
      # depend on to stay embeddable, which landed in the same release. It
      # supersedes the earlier floors, which it still satisfies —
      # V125/V127/V128 for the workflow-status schema and the project-assignee
      # columns, 1.7.184 for the `disabled` / `wrapper_class` / `title` /
      # `:description` attrs on `PhoenixKitWeb.Components.Core.Checkbox`, and
      # 1.7.189 for `PhoenixKit.SchemaPrefix`, which every table-backed schema
      # in this module applies.
      #
      # Bounded with `~>` rather than `>=` on purpose, matching the rest of the
      # module ecosystem: this admits `>= 1.7.231 and < 1.8.0`. Core minors are
      # NOT assumed compatible — a core that renames or drops any of the above
      # should fail resolution here, where the fix is a deliberate re-pin,
      # rather than as a compile error in a consumer's app. Re-pin explicitly
      # when core ships 1.8.
      pk_dep(:phoenix_kit, "~> 2.0"),
      # PhoenixKitAI owns the generic AI-translation pipeline this module's
      # `AITranslatable` / `AITranslateBinding` code plugs into. 0.4 is the
      # floor — that's the release that actually ships the AI-translation move
      # (`PhoenixKitAI.{Translatable,Translations,Components.AITranslate.*}`);
      # 0.3.0 predates it and won't compile against this module.
      pk_dep(:phoenix_kit_ai, "~> 0.18"),
      # 0.3 is the floor: `Assignees` calls
      # `PhoenixKitStaff.Schemas.Person.display_name/1`, which staff first
      # shipped in 0.3.0 (`Team`/`Department.localized_name/2` need 0.2.1).
      # The call is unguarded, so `~> 0.1` admitted releases where building an
      # assignee list raises `UndefinedFunctionError`.
      # Optional (staff-optional seam): the staff DB tables are created by
      # CORE (V100), so projects' shadow schemas and FKs work without this
      # package — it is the people ADMIN surface, not the data's owner.
      # `WITHOUT_STAFF=1 mix compile` drops it entirely, which is the seam's
      # compile gate proving no stray hard reference sneaks back in.
      #
      # The 0.3 floor above still applies whenever staff IS present: making a
      # dependency optional does not make an older release safe.
      pk_dep(:phoenix_kit_staff, "~> 0.8", optional: true),
      # 0.2.6 is the floor: `ProjectShowLive` does `use
      # PhoenixKitComments.Embed`, first published in that release. `~> 0.2`
      # admitted 0.2.0–0.2.5, where that `use` site fails to compile.
      pk_dep(:phoenix_kit_comments, "~> 0.3"),

      # Optional: the entities module is the source/catalog for project
      # workflow statuses. `optional: true` keeps it out of host closures
      # (PhoenixKitProjects.Statuses degrades gracefully when it's absent —
      # mirrors the AI-translation pattern) while making it loadable in this
      # package's own compile + test build.
      pk_dep(:phoenix_kit_entities, "~> 0.3", optional: true),

      # Hard dep: assignment/task schemas reference PhoenixKitStaff.Schemas.*
      # for polymorphic assignee FKs (team / department / person).
      {:phoenix_live_view, "~> 1.1"},
      {:ecto_sql, "~> 3.13"},
      # Gantt/waterfall chart for the project timeline view. 0.4 is the floor —
      # the timeline + the /admin/settings/projects Timeline config use its
      # bar-label API (`label_position` :none/:inside/:outside/:fit/:watermark,
      # `label_side`/`label_overflow`/`label_fit_ratio`/`label_watermark_opacity`),
      # `row_height`/`min_bar_px`, and the arrow-aware label placement added in
      # 0.4.0. Hex by default (publish-safe); export
      # PHOENIX_LIVE_GANTT_PATH=../phoenix_live_gantt to build against a local checkout.
      pk_dep(:phoenix_live_gantt, "~> 0.4"),
      # Calendar/scheduling component used by the Overview dashboard to show all
      # projects as ongoing multi-day bars on a month grid. Hex by default
      # (publish-safe); export PHOENIX_LIVE_CALENDAR_PATH=../phoenix_live_calendar
      # to build against a local checkout.
      pk_dep(:phoenix_live_calendar, "~> 0.3"),
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
    # `pk_dep/3` answers nil for a dep the environment drops (see
    # `dropped_dep?/1`), so the list is compacted rather than each call site
    # growing a conditional.
    |> Enum.reject(&is_nil/1)
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      # `priv/media/` is RUNTIME OUTPUT — the Storage module's default local
      # bucket writes uploads there, and a test run fills it (93 files / ~850K
      # at the time of writing). Gitignoring it is not enough: Hex resolves
      # `files:` against the WORKING DIRECTORY, not git, so an ignored-but-
      # present directory still ships. The published 0.21.1 is clean only
      # because the directory happened to be empty at publish time — run the
      # suite before publishing and it would not have been.
      # (phoenix_kit_entities shipped exactly this way for several releases.)
      exclude_patterns: ["priv/media/"]
    ]
  end

  defp docs do
    [main: "PhoenixKitProjects", source_ref: "v#{@version}"]
  end
end
