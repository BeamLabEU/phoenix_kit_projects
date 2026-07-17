defmodule PhoenixKitProjects do
  @moduledoc """
  Projects module for PhoenixKit.

  Provides a reusable task library, projects that pull tasks in as
  assignments (with team/department/person assignees), and task
  dependency chains within each project.
  """

  use PhoenixKit.Module

  # Single source of truth: read the version from mix.exs at compile time so
  # version/0 can't drift from @version on a release (baked in — no Mix at
  # runtime). The project's own config is in scope when this module compiles.
  @version Mix.Project.config()[:version]

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  @impl PhoenixKit.Module
  def module_key, do: "projects"

  @impl PhoenixKit.Module
  def module_name, do: "Projects"

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting("projects_enabled", false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system do
    Settings.update_boolean_setting_with_module("projects_enabled", true, module_key())
  end

  @impl PhoenixKit.Module
  def disable_system do
    Settings.update_boolean_setting_with_module("projects_enabled", false, module_key())
  end

  @impl PhoenixKit.Module
  def version, do: @version

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Projects",
      icon: "hero-clipboard-document-list",
      description: "Manage projects, tasks, and assignments"
    }
  end

  @impl PhoenixKit.Module
  # Includes :phoenix_live_gantt (Timeline tab) and :phoenix_live_calendar (the
  # Overview calendar) so the host's Tailwind scans their classes with no manual
  # `@source` — the css-sources compiler resolves each dep atom to deps/<dep>.
  def css_sources, do: [:phoenix_kit_projects, :phoenix_live_gantt, :phoenix_live_calendar]

  # The Timeline tab renders the gantt with enable_hooks={true}, so the host's
  # LiveSocket needs the gantt's JS hooks. Declaring the bundle here lets the
  # :phoenix_kit_js_sources compiler wire it into the host automatically — no
  # manual app.js import/spread. The bundle ships in phoenix_live_gantt's priv/.
  #
  # NOTE: no `@impl PhoenixKit.Module` — the core behaviour doesn't declare a
  # `js_sources/0` callback yet (it ships with the core js-sources compiler PR).
  # Annotating @impl against the released core warns ("behaviour does not specify
  # such callback") and fails `mix precommit` (compile --warnings-as-errors).
  # Until core ships the callback this is a harmless plain function core never
  # calls; re-add @impl once the core release includes it.
  def js_sources do
    [
      %{
        app: :phoenix_live_gantt,
        file: "static/assets/phoenix_live_gantt.js",
        global: "PhoenixLiveGanttHooks"
      },
      # The Overview calendar renders without JS (Phoenix-first); these hooks are
      # progressive enhancement (marker ticker / popover-pause) wired the same way
      # as the gantt's so they're available if the calendar opts into them.
      %{
        app: :phoenix_live_calendar,
        file: "static/assets/phoenix_live_calendar.js",
        global: "PhoenixLiveCalendarHooks"
      }
    ]
  end

  def ai_translatables do
    [
      {"project", PhoenixKitProjects.AITranslatable},
      {"template", PhoenixKitProjects.AITranslatable},
      {"task", PhoenixKitProjects.AITranslatable},
      {"assignment", PhoenixKitProjects.AITranslatable}
    ]
  end

  # Dashboard widgets contributed to `phoenix_kit_dashboards` (duck-typed contract
  # discovered by its Registry — no dependency on that package, no `@impl`).
  def phoenix_kit_widgets, do: PhoenixKitProjects.DashboardWidgets.all()

  @impl PhoenixKit.Module
  def admin_tabs do
    parent = [
      %Tab{
        id: :admin_projects,
        label: "Projects",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-clipboard-document-list",
        path: "projects",
        priority: 660,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        live_view: {PhoenixKitProjects.Web.OverviewLive, :index}
      }
    ]

    visible_subtabs = [
      %Tab{
        id: :admin_projects_overview,
        label: "Overview",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-home",
        path: "projects",
        priority: 661,
        level: :admin,
        permission: module_key(),
        match: :exact,
        parent: :admin_projects,
        live_view: {PhoenixKitProjects.Web.OverviewLive, :index}
      },
      %Tab{
        id: :admin_projects_templates,
        label: "Templates",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-document-duplicate",
        path: "projects/templates",
        priority: 662,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_projects,
        live_view: {PhoenixKitProjects.Web.TemplatesLive, :index}
      },
      %Tab{
        id: :admin_projects_tasks,
        label: "Tasks",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-rectangle-stack",
        path: "projects/tasks",
        priority: 663,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_projects,
        live_view: {PhoenixKitProjects.Web.TasksLive, :index}
      },
      %Tab{
        id: :admin_projects_list,
        label: "Projects",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-clipboard-document-list",
        path: "projects/list",
        priority: 664,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_projects,
        live_view: {PhoenixKitProjects.Web.ProjectsLive, :index}
      }
    ]

    hidden_subtabs = [
      %Tab{
        id: :admin_projects_task_new,
        label: "New Task",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/tasks/new",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.TaskFormLive, :new}
      },
      %Tab{
        id: :admin_projects_task_edit,
        label: "Edit Task",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/tasks/:id/edit",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.TaskFormLive, :edit}
      },
      %Tab{
        id: :admin_projects_project_new,
        label: "New Project",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/list/new",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectFormLive, :new}
      },
      %Tab{
        id: :admin_projects_project_edit,
        label: "Edit Project",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/list/:id/edit",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectFormLive, :edit}
      },
      %Tab{
        id: :admin_projects_project_show,
        label: "Project",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/list/:id",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :show}
      },
      %Tab{
        id: :admin_projects_project_gantt,
        label: "Timeline",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/list/:id/gantt",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        # Same LiveView as the show page, different live_action — the gantt is a
        # tab on the show page, not a separate page. `:gantt` selects that tab.
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :gantt}
      },
      %Tab{
        id: :admin_projects_project_calendar,
        label: "Calendar",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/list/:id/calendar",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        # Same LiveView as the show page, different live_action — the calendar
        # is a tab on the show page, not a separate page. `:calendar` selects it.
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :calendar}
      },
      %Tab{
        id: :admin_projects_template_new,
        label: "New Template",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/templates/new",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.TemplateFormLive, :new}
      },
      %Tab{
        id: :admin_projects_template_edit,
        label: "Edit Template",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/templates/:id/edit",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.TemplateFormLive, :edit}
      },
      %Tab{
        id: :admin_projects_template_show,
        label: "Template",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/templates/:id",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectShowLive, :show_template}
      },
      %Tab{
        id: :admin_projects_assignment_new,
        label: "Add Task",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/list/:project_id/assignments/new",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.AssignmentFormLive, :new}
      },
      %Tab{
        id: :admin_projects_assignment_edit,
        label: "Edit Assignment",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/list/:project_id/assignments/:id/edit",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.AssignmentFormLive, :edit}
      }
    ]

    parent ++ visible_subtabs ++ hidden_subtabs
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_projects,
        label: "Projects",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-clipboard-document-list",
        path: "projects",
        priority: 930,
        level: :admin,
        parent: :admin_settings,
        permission: module_key(),
        live_view: {PhoenixKitProjects.Web.ProjectsSettingsLive, :settings}
      )
    ]
  end
end
