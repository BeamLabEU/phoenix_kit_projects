defmodule PhoenixKitProjects.DashboardWidgets do
  @moduledoc """
  The dashboard **widgets** `phoenix_kit_projects` contributes to
  `phoenix_kit_dashboards`.

  Exposed through `PhoenixKitProjects.phoenix_kit_widgets/0` — a plain-map,
  one-way contract: projects knows nothing about the dashboards package; the
  dashboards Registry discovers this list, normalizes each map into a `%Widget{}`,
  and gates visibility on the `"projects"` module being enabled + permitted.

  Each `:component` is a `Phoenix.LiveComponent` under
  `PhoenixKitProjects.Web.Widgets.*` that receives `settings` / `view` / `size` /
  `scope` and re-queries on the host's refresh tick. Views declare their own
  `min_size` where the layouts genuinely differ (a detailed table needs more
  room than a KPI strip), so the dashboards builder floors resizing per view.
  Sizes are in the dashboards **lattice units** (25px nominal square cells —
  a screenful is e.g. 64×36).

  The single-project widgets pick their project from a **select of current
  projects** (`project_options/0` — evaluated when the widget catalog is built,
  so a brand-new project appears after a registry refresh). The stored value is
  the project uuid; the blank option means "first running project", and stale
  stored values still resolve leniently (uuid / name / external id / substring)
  via `Web.Widgets.Helpers.resolve_project/1`.
  """

  alias PhoenixKitProjects.Projects

  alias PhoenixKitProjects.Web.Widgets.{
    CalendarWidget,
    DeadlinesWidget,
    MyTasksWidget,
    OngoingTasksWidget,
    ProjectsBoardWidget,
    ProjectScheduleWidget,
    ProjectStatusWidget,
    RunningWidget,
    UpcomingWidget,
    WorkloadWidget
  }

  @doc """
  Select options for the `"project"` setting: `{name, uuid}` for every current
  (non-template, non-archived) project, blank = first running. Degrades to just
  the blank option when the module/tables aren't available.
  """
  # ⚠ NOT viewer-scoped, and cannot be from here: the catalog (and this
  # select's options with it) is built once, with no viewer in hand — the
  # widget-settings contract in phoenix_kit_dashboards would have to pass a
  # scope through. So this dropdown still names every project to anyone who
  # can edit a dashboard widget.
  #
  # What it no longer does is grant access: `Widgets.Helpers.resolve_project/2`
  # re-checks :view on whatever the setting names, so picking a project you
  # cannot see renders the widget's empty state. Names and uuids in the
  # select are the residual exposure; closing it needs the sibling contract
  # change.
  @spec project_options() :: [{String.t(), String.t()}]
  def project_options do
    prompt = {"First running project", ""}

    options =
      Projects.list_projects()
      |> Enum.map(fn p -> {p.name || p.uuid, p.uuid} end)
      |> Enum.sort_by(fn {name, _} -> name end)

    [prompt | options]
  rescue
    # Catalog building must never crash widget discovery on a DB hiccup,
    # but a silent swallow would mask a real bug as an eternally-empty
    # select — log like every other DB-read resilience rescue in this
    # module. Scoped to DB errors only, not a bare rescue: a genuine
    # programming error here should surface, not degrade-and-log.
    e in [
      Postgrex.Error,
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Ecto.QueryError
    ] ->
      require Logger
      Logger.warning("[DashboardWidgets] project_options failed: #{Exception.message(e)}")
      [{"First running project", ""}]
  end

  defp project_field do
    %{
      key: "project",
      type: :select,
      label: "Project",
      options: project_options(),
      default: ""
    }
  end

  @limit_field %{key: "limit", type: :number, label: "Max rows", default: "6"}

  @doc "The list of widget definitions (plain maps) for `phoenix_kit_widgets/0`."
  @spec all() :: [map()]
  def all do
    [
      %{
        key: "projects.board",
        name: "Projects board",
        description: "Every project at a glance, coloured by status.",
        icon: "hero-squares-2x2",
        module_key: "projects",
        component: ProjectsBoardWidget,
        category: "Projects",
        default_size: %{w: 24, h: 12},
        min_size: %{w: 8, h: 4},
        refresh_interval: 15_000,
        views: [
          %{key: "grid", name: "Grid", min_size: %{w: 12, h: 8}},
          %{key: "counts", name: "Counts", min_size: %{w: 8, h: 4}}
        ]
      },
      %{
        key: "projects.workload",
        name: "Projects workload",
        description: "Project lifecycle + task workload counts for the whole workspace.",
        icon: "hero-chart-pie",
        module_key: "projects",
        component: WorkloadWidget,
        category: "Projects",
        default_size: %{w: 16, h: 8},
        min_size: %{w: 8, h: 4},
        refresh_interval: 15_000,
        views: [
          %{key: "detailed", name: "Detailed", min_size: %{w: 12, h: 8}},
          %{key: "simple", name: "Simple (KPIs)", min_size: %{w: 8, h: 4}}
        ]
      },
      %{
        key: "projects.my_tasks",
        name: "My tasks",
        description: "Your open assignments across every active project.",
        icon: "hero-user-circle",
        module_key: "projects",
        component: MyTasksWidget,
        category: "Projects",
        default_size: %{w: 16, h: 12},
        min_size: %{w: 8, h: 8},
        refresh_interval: 15_000,
        views: [
          %{key: "detailed", name: "Detailed", min_size: %{w: 12, h: 8}},
          %{key: "compact", name: "Compact", min_size: %{w: 8, h: 8}}
        ],
        settings_schema: [%{@limit_field | default: "8"}]
      },
      %{
        key: "projects.deadlines",
        name: "Deadlines",
        description: "Running projects by nearest planned end — overdue flagged.",
        icon: "hero-flag",
        module_key: "projects",
        component: DeadlinesWidget,
        category: "Projects",
        default_size: %{w: 16, h: 12},
        min_size: %{w: 8, h: 8},
        refresh_interval: 30_000,
        views: [
          %{key: "detailed", name: "Detailed", min_size: %{w: 12, h: 8}},
          %{key: "compact", name: "Compact", min_size: %{w: 8, h: 8}}
        ],
        settings_schema: [
          @limit_field,
          %{key: "only_mine", type: :boolean, label: "Only my projects", default: false}
        ]
      },
      # The Overview dashboard's pieces (the page lost its admin route in
      # 2026-09 — the boss wants module dashboards assembled in the dashboards
      # module): its Running list and its side column. Together with
      # `projects.my_tasks`, `projects.workload` (the stat tiles) and
      # `projects.calendar`, a system dashboard can stand in for the page.
      %{
        key: "projects.running",
        name: "Running projects",
        description:
          "Running projects in the Overview's order — late first, then near done — with tier and progress.",
        icon: "hero-play-circle",
        module_key: "projects",
        component: RunningWidget,
        category: "Projects",
        default_size: %{w: 16, h: 12},
        min_size: %{w: 8, h: 8},
        refresh_interval: 15_000,
        views: [
          %{key: "compact", name: "Compact", min_size: %{w: 8, h: 8}},
          %{key: "cards", name: "Cards (with sub-projects)", min_size: %{w: 16, h: 12}}
        ],
        settings_schema: [
          @limit_field,
          %{key: "late_only", type: :boolean, label: "Late projects only", default: false}
        ]
      },
      %{
        key: "projects.calendar",
        name: "Projects calendar",
        description:
          "Every scheduled task across projects on its days (or one line per project), late marked.",
        icon: "hero-calendar-days",
        module_key: "projects",
        component: CalendarWidget,
        category: "Projects",
        default_size: %{w: 32, h: 24},
        min_size: %{w: 12, h: 10},
        refresh_interval: 60_000,
        views: [
          %{key: "month", name: "Month grid", min_size: %{w: 20, h: 16}},
          %{key: "agenda", name: "Agenda", min_size: %{w: 12, h: 10}}
        ],
        settings_schema: [
          %{
            key: "mode",
            type: :select,
            label: "Show",
            default: "tasks",
            options: [
              {"Tasks (one chip per task)", "tasks"},
              {"Projects (one line per project)", "projects"}
            ]
          },
          %{key: "only_mine", type: :boolean, label: "Only my tasks", default: false},
          %{key: "late_only", type: :boolean, label: "Late only", default: false}
        ]
      },
      %{
        key: "projects.upcoming",
        name: "Upcoming & completed",
        description:
          "Projects in setup or scheduled to start, or the most recently completed ones.",
        icon: "hero-calendar",
        module_key: "projects",
        component: UpcomingWidget,
        category: "Projects",
        default_size: %{w: 16, h: 8},
        min_size: %{w: 8, h: 6},
        refresh_interval: 30_000,
        views: [
          %{key: "upcoming", name: "Upcoming (setup + scheduled)", min_size: %{w: 8, h: 6}},
          %{key: "completed", name: "Recently completed", min_size: %{w: 8, h: 6}}
        ],
        settings_schema: [@limit_field]
      },
      %{
        key: "projects.status",
        name: "Project status",
        description: "One project's lifecycle, status, progress and ETA.",
        icon: "hero-clipboard-document-check",
        module_key: "projects",
        component: ProjectStatusWidget,
        category: "Projects",
        default_size: %{w: 16, h: 12},
        min_size: %{w: 8, h: 8},
        refresh_interval: 15_000,
        views: [
          %{key: "detailed", name: "Detailed", min_size: %{w: 12, h: 8}},
          %{key: "simple", name: "Simple", min_size: %{w: 8, h: 8}}
        ],
        settings_schema: [project_field()]
      },
      %{
        key: "projects.tasks",
        name: "Ongoing tasks",
        description: "The current todo + in-progress tasks of a project.",
        icon: "hero-list-bullet",
        module_key: "projects",
        component: OngoingTasksWidget,
        category: "Projects",
        default_size: %{w: 16, h: 12},
        min_size: %{w: 8, h: 8},
        refresh_interval: 15_000,
        views: [
          %{key: "detailed", name: "Detailed", min_size: %{w: 12, h: 8}},
          %{key: "compact", name: "Compact", min_size: %{w: 8, h: 8}}
        ],
        settings_schema: [
          project_field(),
          %{@limit_field | label: "Max tasks"}
        ]
      },
      %{
        key: "projects.schedule",
        name: "Project schedule",
        description: "One project's estimate, planned end and live ETA.",
        icon: "hero-calendar-days",
        module_key: "projects",
        component: ProjectScheduleWidget,
        category: "Projects",
        default_size: %{w: 16, h: 8},
        min_size: %{w: 8, h: 4},
        refresh_interval: 30_000,
        views: [
          %{key: "detailed", name: "Detailed", min_size: %{w: 12, h: 8}},
          %{key: "simple", name: "Simple", min_size: %{w: 8, h: 4}}
        ],
        settings_schema: [project_field()]
      }
    ]
  end
end
