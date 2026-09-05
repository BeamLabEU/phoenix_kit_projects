defmodule PhoenixKitProjects.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitProjects.Paths` so `live/2` calls in tests
  use the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when
  the phoenix_kit_settings table is unavailable, and admin paths
  always get the default locale ("en") prefix — so our base becomes
  `/en/admin/projects`.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitProjects.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/en/admin/projects", PhoenixKitProjects.Web do
    pipe_through(:browser)

    live_session :projects_test,
      layout: {PhoenixKitProjects.Test.Layouts, :app},
      on_mount: {PhoenixKitProjects.Test.Hooks, :assign_scope} do
      # Same shape and ORDER as the module's admin_tabs/0 (routes are emitted
      # in that order and Phoenix matches in declaration order): the literal
      # subtabs and the legacy redirects before `/:id`, `/new` before `/:id`.
      live("/", ProjectsLive, :index)
      live("/templates", TemplatesLive, :index)
      live("/tasks", TasksLive, :index)
      live("/overview", OverviewLive, :index)

      # Legacy `list/…` addresses redirect to the same path without the segment.
      live("/list", ListRedirectLive, :index)
      live("/list/*rest", ListRedirectLive, :index)

      live("/tasks/new", TaskFormLive, :new)
      live("/tasks/:id/edit", TaskFormLive, :edit)

      live("/new", ProjectFormLive, :new)
      live("/:id", ProjectShowLive, :show)
      live("/:id/board", ProjectShowLive, :board)
      live("/:id/gantt", ProjectShowLive, :gantt)
      live("/:id/calendar", ProjectShowLive, :calendar)
      live("/:id/edit", ProjectFormLive, :edit)
      live("/:id/modules", ProjectModulesLive, :edit)
      live("/:id/members", ProjectMembersLive, :edit)
      live("/:id/files", ProjectFilesLive, :edit)
      live("/:id/activity", ProjectActivityLive, :index)
      # The project page's top-level tabs (the `:tab` catch-all is last, below).
      live("/:id/tasks", ProjectShowLive, :tasks)
      live("/:id/tasks/board", ProjectShowLive, :board)
      live("/:id/tasks/timeline", ProjectShowLive, :gantt)
      live("/:id/tasks/calendar", ProjectShowLive, :calendar)
      live("/:id/comments", ProjectShowLive, :comments)

      live("/templates/new", TemplateFormLive, :new)
      live("/templates/:id", ProjectShowLive, :show_template)
      live("/templates/:id/edit", TemplateFormLive, :edit)

      live("/:project_id/assignments/new", AssignmentFormLive, :new)
      live("/:project_id/assignments/:id/edit", AssignmentFormLive, :edit)

      # Last: the extension-tab catch-all (mirrors the module's route order).
      live("/:id/:tab", ProjectShowLive, :ext_tab)
    end
  end

  # The PUBLIC portal — production mounts it via the module's
  # route_module/0 (`Web.Routes.generate/1`). The scope hook is mirrored
  # here because a `members` board asks whether the visitor is signed in,
  # and without it every portal test would look anonymous.
  scope "/", PhoenixKitProjects.Web do
    pipe_through(:browser)

    live_session :projects_portal_test,
      on_mount: [{PhoenixKitProjects.Test.Hooks, :assign_scope}] do
      live("/portal/:slug", PortalLive, :show)
      live("/portal/:slug/i/:issue", PortalLive, :issue)
      live("/portal/:slug/report", PortalLive, :report)
    end
  end

  # The member-facing user-dashboard surface — production mounts it via
  # `user_dashboard_tabs/0` route discovery under core's authenticated
  # /dashboard session.
  scope "/en/dashboard", PhoenixKitProjects.Web do
    pipe_through(:browser)

    live_session :projects_member_test,
      layout: {PhoenixKitProjects.Test.Layouts, :app},
      on_mount: {PhoenixKitProjects.Test.Hooks, :assign_scope} do
      live("/projects", MemberProjectsLive, :index)
    end
  end

  # Global Projects settings page — production mounts it via the module's
  # `settings_tabs/0` callback under the core `/admin/settings` area.
  scope "/en/admin/settings", PhoenixKitProjects.Web do
    pipe_through(:browser)

    live_session :projects_settings_test,
      layout: {PhoenixKitProjects.Test.Layouts, :app},
      on_mount: {PhoenixKitProjects.Test.Hooks, :assign_scope} do
      live("/projects", ProjectsSettingsLive, :settings)
    end
  end
end
