defmodule PhoenixKitProjects.Paths do
  @moduledoc "Centralized path helpers for the Projects module."

  alias PhoenixKit.Utils.Routes

  @base "/admin/projects"

  @doc "Projects dashboard root."
  @spec index() :: String.t()
  def index, do: Routes.path(@base)

  @doc "Projects settings page (global, under the core Settings area)."
  @spec settings() :: String.t()
  def settings, do: Routes.path("/admin/settings/projects")

  # Task library
  @doc "Task-library index."
  @spec tasks() :: String.t()
  def tasks, do: Routes.path("#{@base}/tasks")
  @doc "New-task form."
  @spec new_task() :: String.t()
  def new_task, do: Routes.path("#{@base}/tasks/new")
  @doc "Edit form for a task."
  @spec edit_task(String.t()) :: String.t()
  def edit_task(id), do: Routes.path("#{@base}/tasks/#{id}/edit")

  # Templates
  @doc "Templates index."
  @spec templates() :: String.t()
  def templates, do: Routes.path("#{@base}/templates")
  @doc "New-template form."
  @spec new_template() :: String.t()
  def new_template, do: Routes.path("#{@base}/templates/new")
  @doc "Show page for a single template."
  @spec template(String.t()) :: String.t()
  def template(id), do: Routes.path("#{@base}/templates/#{id}")
  @doc "Edit form for a template."
  @spec edit_template(String.t()) :: String.t()
  def edit_template(id), do: Routes.path("#{@base}/templates/#{id}/edit")

  # Projects
  @doc "Projects (non-template) index."
  @spec projects() :: String.t()
  def projects, do: Routes.path("#{@base}/list")
  @doc "New-project form."
  @spec new_project() :: String.t()
  def new_project, do: Routes.path("#{@base}/list/new")
  @doc "Show page for a single project."
  @spec project(String.t()) :: String.t()
  def project(id), do: Routes.path("#{@base}/list/#{id}")
  @doc "Gantt/waterfall timeline view for a single project."
  @spec project_gantt(String.t()) :: String.t()
  def project_gantt(id), do: Routes.path("#{@base}/list/#{id}/gantt")
  @doc "Month-calendar view for a single project."
  @spec project_calendar(String.t()) :: String.t()
  def project_calendar(id), do: Routes.path("#{@base}/list/#{id}/calendar")
  @doc "Edit form for a project."
  @spec edit_project(String.t()) :: String.t()
  def edit_project(id), do: Routes.path("#{@base}/list/#{id}/edit")

  # Assignments (within a project)
  @doc "New-assignment form nested under a project."
  @spec new_assignment(String.t()) :: String.t()
  def new_assignment(project_id), do: Routes.path("#{@base}/list/#{project_id}/assignments/new")

  @doc "Edit form for an assignment nested under a project."
  @spec edit_assignment(String.t(), String.t()) :: String.t()
  def edit_assignment(project_id, id),
    do: Routes.path("#{@base}/list/#{project_id}/assignments/#{id}/edit")
end
