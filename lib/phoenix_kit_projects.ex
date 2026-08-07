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
    result = Settings.update_boolean_setting_with_module("projects_enabled", true, module_key())

    # Rebuild the extension catalog on our own enable so providers that
    # appeared while we were off are discovered without a restart (the
    # dashboards-Registry precedent; a Grok panel finding caught the
    # Registry moduledoc promising this before it was wired).
    try do
      PhoenixKitProjects.Extensions.Registry.refresh()
    rescue
      _ -> :ok
    end

    result
  end

  @impl PhoenixKit.Module
  def disable_system do
    Settings.update_boolean_setting_with_module("projects_enabled", false, module_key())
  end

  @impl PhoenixKit.Module
  def version, do: @version

  @impl PhoenixKit.Module
  @doc """
  Notification preference types (Step 7 of the hub rework): the actions
  below fan out through core's activity→notification bridge whenever their
  entries carry a `target_uuid` (the affected user — assignees on task
  actions, the member on membership actions). Users tune each sub-type —
  and its Email/Telegram routing — in their notification preferences.
  """
  def notification_types do
    [
      %{
        key: "projects",
        label: "Projects",
        description: "Membership, health, and task updates in your projects",
        actions: [],
        default: true,
        sub_types: [
          %{
            key: "membership",
            label: "Membership",
            description: "Added to a project, role changes, removals",
            actions: [
              "projects.member_added",
              "projects.member_role_changed",
              "projects.member_removed"
            ],
            default: true
          },
          %{
            key: "tasks",
            label: "Task updates",
            description: "Tasks assigned to you created, edited, or moved",
            actions: [
              "projects.assignment_created",
              "projects.assignment_updated",
              "projects.assignment_started",
              "projects.assignment_completed",
              "projects.assignment_reopened"
            ],
            default: true
          },
          %{
            key: "health",
            label: "Project health",
            description: "Health judgments on your projects",
            actions: ["projects.health_updated"],
            default: true
          },
          %{
            key: "events",
            label: "Project events",
            description: "Meetings, milestones, and reviews added to your projects",
            actions: [
              "projects.event_created",
              "projects.event_updated",
              "projects.event_deleted"
            ],
            default: true
          }
        ]
      }
    ]
  end

  @impl PhoenixKit.Module
  # Module-owned migration chain (V1 = baseline of the core-built V101..V128
  # shape; V2+ = hub-rework tables). Discovered by `mix phoenix_kit.update`,
  # which compares current_version/0 vs migrated_version_runtime/1 and
  # generates a host migration delegating to Schema.up/1. See the Schema
  # moduledoc for the core-chain handover contract.
  def migration_module, do: PhoenixKitProjects.Migrations.Schema

  # AI usage sink (the attribution wave, Phase G): phoenix_kit_ai's
  # dispatch_usage_sinks/1 calls every discovered module exporting this
  # function with each persisted %Request{} — duck-typed, no dependency
  # on that package. Resolution + the ledger write live in the Ledger's
  # attribution helper; a request without a resolvable projects
  # attribution is simply not ours.
  def handle_ai_usage(request) do
    PhoenixKitProjects.Ledger.record_ai_request(request)
  end

  @impl PhoenixKit.Module
  # Lifecycle hook: core calls this BEFORE a user row deletes, while
  # memberships still exist. RELEASE-GATED: the callback ships in an
  # unreleased core, so the Hex-pin build won't compile until that
  # release — gates run via PHOENIX_KIT_PATH (the admin-ui-overhaul
  # precedent). Sole-owner departures get succession or an
  # orphan-warning audit row.
  def before_user_delete(user_uuid) do
    PhoenixKitProjects.Members.handle_user_deletion(user_uuid)
  end

  @impl PhoenixKit.Module
  # Public portal routes (/portal/:slug) — the admin surface stays on the
  # admin_tabs/user_dashboard_tabs auto-generation.
  def route_module, do: PhoenixKitProjects.Web.Routes

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Projects",
      icon: "hero-clipboard-document-list",
      description: "Reach the Projects module — see the projects you belong to",
      sub_permissions: [
        # The base key used to mean "do everything on every project": the
        # resolver short-circuited on module access before membership was
        # ever consulted, so granting a contractor's role the projects
        # permission handed them full power over every project on the site.
        # Splitting it makes the base key mean "may enter the module" and
        # this one mean "administer projects you are not a member of".
        # Core auto-grants declared sub-keys to Admin at boot, Owner rides
        # the "*" wildcard, and `migrate_legacy/0` carries every other role
        # that already held the base key — so nobody loses access, while a
        # role granted the base key from now on gets no such power.
        %{
          key: "admin_all",
          label: "Administer all projects",
          description:
            "See and manage every project on the site, including ones this user is not a member of"
        }
      ]
    }
  end

  @doc """
  Grants `projects.admin_all` to every role that already holds the base
  `projects` key, preserving the pre-split behavior for existing installs.

  Idempotent (a role that already holds it is skipped) and safe to re-run on
  every boot, which is how core invokes it. Deliberately one-way: it never
  revokes, so an Owner who removes the sub-key from a role keeps that
  decision.
  """
  def migrate_legacy do
    alias PhoenixKit.Users.{Permissions, Roles}

    Enum.each(Roles.list_roles(), fn role ->
      granted = Permissions.get_permissions_for_role(role.uuid)

      if "projects" in granted and "projects.admin_all" not in granted do
        Permissions.grant_permission(role.uuid, "projects.admin_all", nil)
      end
    end)

    :ok
  rescue
    error ->
      {:error, Exception.message(error)}
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

  # Project-extension catalog entries (the hub's own duck-typed provider
  # contract — `PhoenixKitProjects.Extensions.Registry` discovers this same
  # function on every module, ours included; no `@impl`, mirrors
  # `phoenix_kit_widgets/0`). The built-in Tasks extension ships
  # `default_enabled: true` so every pre-hub project keeps its task surface
  # unchanged — the hub's behavior-preserving default. Its feature flags land
  # with the Features layer (Step 3 of the 2026-08-05 plan); tabs stay native
  # on the show page until enforcement threading gates them.
  def phoenix_kit_project_extensions do
    [
      %{
        key: "tasks",
        name: "Tasks",
        description: "Task lists, dependencies, scheduling, Timeline and Calendar views",
        icon: "hero-clipboard-document-list",
        module_key: nil,
        default_enabled: true,
        permission_actions: [
          :create_tasks,
          :edit_tasks,
          :delete_tasks,
          :assign_tasks,
          :update_status,
          :log_time
        ],
        # The FROZEN pre-hub flag catalog (2026-08-05 panel amendment #6):
        # every flag defaults true so existing projects are unchanged with
        # no backfill; `requires` is the resolution-time dependency rule
        # (Features.on?/2 — a flag is dead while any requirement is off).
        # The "simple todo list" preset is these, explicitly false.
        feature_flags: [
          %{key: "assignees", label: "Assignees", default: true},
          %{key: "estimates", label: "Estimates & durations", default: true},
          %{key: "progress", label: "Progress tracking", default: true, requires: []},
          %{key: "dependencies", label: "Dependencies", default: true},
          %{key: "statuses", label: "Workflow statuses", default: true},
          %{key: "scheduling", label: "Scheduling & ETA", default: true, requires: ["estimates"]},
          %{key: "subprojects", label: "Sub-projects", default: true},
          %{key: "priorities", label: "Priorities", default: true},
          %{key: "labels", label: "Labels", default: true},
          %{key: "ledger", label: "Work ledger", default: true},
          %{key: "view_board", label: "Board view", default: true},
          %{
            key: "view_timeline",
            label: "Timeline view",
            default: true,
            requires: ["scheduling"]
          },
          %{
            key: "view_calendar",
            label: "Calendar view",
            default: true,
            requires: ["scheduling"]
          }
        ]
      },
      %{
        key: "files",
        name: "Files",
        description: "Attach files to the project (core media library)",
        icon: "hero-paper-clip",
        module_key: nil,
        default_enabled: true,
        permission_actions: [:upload_files]
      },
      # Whiteboards (Step 11): built-in extension whose surface is a
      # contributed tab through the SAME pipeline external providers use —
      # dogfooding the tab contract. Off by default: drawing boards are an
      # opt-in capability, not part of the pre-hub surface.
      %{
        key: "whiteboards",
        name: "Whiteboards",
        description: "Freeform drawing boards on the core annotation canvas",
        icon: "hero-paint-brush",
        module_key: nil,
        default_enabled: false,
        permission_actions: [:upload_files],
        tabs: [
          %{
            key: "boards",
            label: "Whiteboards",
            icon: "hero-paint-brush",
            lv: PhoenixKitProjects.Web.ProjectWhiteboardsLive
          }
        ]
      },
      # Events (Step 12): dated happenings that aren't tasks — meetings,
      # milestones, reviews — on their own calendar tab. Off by default.
      %{
        key: "events",
        name: "Events",
        description: "Meetings, milestones, and reviews on a project calendar",
        icon: "hero-calendar-days",
        module_key: nil,
        default_enabled: false,
        permission_actions: [:create_tasks],
        tabs: [
          %{
            key: "events",
            label: "Events",
            icon: "hero-calendar-days",
            lv: PhoenixKitProjects.Web.ProjectEventsLive
          }
        ]
      },
      # Hub-side BRIDGE descriptor for a module that doesn't self-declare
      # (phoenix_kit_comments is BeamLab-maintained): the show page's
      # comments drawer, re-fronted as a per-project toggle. The drawer's
      # own availability check still applies — this gate composes with it.
      %{
        key: "discussions",
        name: "Discussions",
        description: "Comment threads on the project and its tasks",
        icon: "hero-chat-bubble-left-right",
        module_key: "comments",
        default_enabled: true,
        permission_actions: [:comment]
      },
      # Public portal (Phase J): anonymous issue intake + a public issue
      # list/status page behind a random capability link. Off by default
      # everywhere; the security model lives in PhoenixKitProjects.Portal
      # (2026-08-06 design doc + the external security panel's findings).
      %{
        key: "portal",
        name: "Public portal",
        description: "Anonymous issue submission and a public status page behind a private link",
        icon: "hero-globe-alt",
        module_key: nil,
        default_enabled: false,
        permission_actions: [:edit_tasks],
        on_enable: {PhoenixKitProjects.Portal, :ensure_portal},
        feature_flags: [
          %{key: "portal_submit", label: "Public issue submission", default: true},
          %{key: "portal_list", label: "Public issue list", default: true},
          %{key: "portal_status", label: "Public status summary", default: true}
        ]
      }
    ]
  end

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
        id: :admin_projects_files,
        label: "Project Files",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/list/:id/files",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectFilesLive, :edit}
      },
      %Tab{
        id: :admin_projects_activity,
        label: "Project Activity",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/list/:id/activity",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectActivityLive, :index}
      },
      %Tab{
        id: :admin_projects_members,
        label: "Project Members",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/list/:id/members",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectMembersLive, :edit}
      },
      %Tab{
        id: :admin_projects_modules,
        label: "Project Modules",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        path: "projects/list/:id/modules",
        level: :admin,
        permission: module_key(),
        parent: :admin_projects,
        visible: false,
        live_view: {PhoenixKitProjects.Web.ProjectModulesLive, :edit}
      },
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
  # The member-facing surface (Phase I): a "My Projects" page on the USER
  # dashboard — membership-gated, no admin permission. The `live_view`
  # field makes core's authenticated route table generate
  # `/dashboard/projects` automatically (the user_dashboard_tabs route
  # discovery this module is the first consumer of).
  def user_dashboard_tabs do
    [
      %Tab{
        id: :dashboard_projects,
        label: "My Projects",
        gettext_backend: PhoenixKitProjects.Gettext,
        gettext_domain: "default",
        icon: "hero-briefcase",
        path: "projects",
        priority: 250,
        match: :prefix,
        group: :main,
        live_view: {PhoenixKitProjects.Web.MemberProjectsLive, :index}
      }
    ]
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
