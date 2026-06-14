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
      live("/", OverviewLive, :index)

      live("/tasks", TasksLive, :index)
      live("/tasks/new", TaskFormLive, :new)
      live("/tasks/:id/edit", TaskFormLive, :edit)

      live("/list", ProjectsLive, :index)
      live("/list/new", ProjectFormLive, :new)
      live("/list/:id", ProjectShowLive, :show)
      live("/list/:id/gantt", ProjectShowLive, :gantt)
      live("/list/:id/edit", ProjectFormLive, :edit)

      live("/list/:project_id/assignments/new", AssignmentFormLive, :new)
      live("/list/:project_id/assignments/:id/edit", AssignmentFormLive, :edit)

      live("/templates", TemplatesLive, :index)
      live("/templates/new", TemplateFormLive, :new)
      live("/templates/:id", ProjectShowLive, :show_template)
      live("/templates/:id/edit", TemplateFormLive, :edit)
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
