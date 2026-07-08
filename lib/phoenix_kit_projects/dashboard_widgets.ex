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

  The single-project widgets pick their project from a **select of current
  projects** (`project_options/0` — evaluated when the widget catalog is built,
  so a brand-new project appears after a registry refresh). The stored value is
  the project uuid; the blank option means "first running project", and stale
  stored values still resolve leniently (uuid / name / external id / substring)
  via `Web.Widgets.Helpers.resolve_project/1`.
  """

  alias PhoenixKitProjects.Projects

  alias PhoenixKitProjects.Web.Widgets.{
    DeadlinesWidget,
    MyTasksWidget,
    OngoingTasksWidget,
    ProjectsBoardWidget,
    ProjectScheduleWidget,
    ProjectStatusWidget,
    WorkloadWidget
  }

  @doc """
  Select options for the `"project"` setting: `{name, uuid}` for every current
  (non-template, non-archived) project, blank = first running. Degrades to just
  the blank option when the module/tables aren't available.
  """
  @spec project_options() :: [{String.t(), String.t()}]
  def project_options do
    prompt = {"First running project", ""}

    options =
      Projects.list_projects()
      |> Enum.map(fn p -> {p.name || p.uuid, p.uuid} end)
      |> Enum.sort_by(fn {name, _} -> name end)

    [prompt | options]
  rescue
    _ -> [{"First running project", ""}]
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
        default_size: %{w: 6, h: 3},
        min_size: %{w: 2, h: 1},
        refresh_interval: 15_000,
        views: [
          %{key: "grid", name: "Grid", min_size: %{w: 3, h: 2}},
          %{key: "counts", name: "Counts", min_size: %{w: 2, h: 1}}
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
        default_size: %{w: 4, h: 2},
        min_size: %{w: 2, h: 1},
        refresh_interval: 15_000,
        views: [
          %{key: "detailed", name: "Detailed", min_size: %{w: 3, h: 2}},
          %{key: "simple", name: "Simple (KPIs)", min_size: %{w: 2, h: 1}}
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
        default_size: %{w: 4, h: 3},
        min_size: %{w: 2, h: 2},
        refresh_interval: 15_000,
        views: [
          %{key: "detailed", name: "Detailed", min_size: %{w: 3, h: 2}},
          %{key: "compact", name: "Compact", min_size: %{w: 2, h: 2}}
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
        default_size: %{w: 4, h: 3},
        min_size: %{w: 2, h: 2},
        refresh_interval: 30_000,
        views: [
          %{key: "detailed", name: "Detailed", min_size: %{w: 3, h: 2}},
          %{key: "compact", name: "Compact", min_size: %{w: 2, h: 2}}
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
        default_size: %{w: 4, h: 3},
        min_size: %{w: 2, h: 2},
        refresh_interval: 15_000,
        views: [
          %{key: "detailed", name: "Detailed", min_size: %{w: 3, h: 2}},
          %{key: "simple", name: "Simple", min_size: %{w: 2, h: 2}}
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
        default_size: %{w: 4, h: 3},
        min_size: %{w: 2, h: 2},
        refresh_interval: 15_000,
        views: [
          %{key: "detailed", name: "Detailed", min_size: %{w: 3, h: 2}},
          %{key: "compact", name: "Compact", min_size: %{w: 2, h: 2}}
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
        default_size: %{w: 4, h: 2},
        min_size: %{w: 2, h: 1},
        refresh_interval: 30_000,
        views: [
          %{key: "detailed", name: "Detailed", min_size: %{w: 3, h: 2}},
          %{key: "simple", name: "Simple", min_size: %{w: 2, h: 1}}
        ],
        settings_schema: [project_field()]
      }
    ]
  end
end
