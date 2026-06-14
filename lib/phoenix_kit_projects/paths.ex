defmodule PhoenixKitProjects.Paths do
  @moduledoc "Centralized path helpers for the Projects module."

  alias PhoenixKit.Utils.Routes

  @base "/admin/projects"

  @doc "Projects dashboard root."
  def index, do: Routes.path(@base)

  @doc "Projects settings page (global, under the core Settings area)."
  def settings, do: Routes.path("/admin/settings/projects")

  # Task library
  @doc "Task-library index."
  def tasks, do: Routes.path("#{@base}/tasks")
  @doc "New-task form."
  def new_task, do: Routes.path("#{@base}/tasks/new")
  @doc "Edit form for a task."
  def edit_task(id), do: Routes.path("#{@base}/tasks/#{id}/edit")

  # Templates
  @doc "Templates index."
  def templates, do: Routes.path("#{@base}/templates")
  @doc "New-template form."
  def new_template, do: Routes.path("#{@base}/templates/new")
  @doc "Show page for a single template."
  def template(id), do: Routes.path("#{@base}/templates/#{id}")
  @doc "Edit form for a template."
  def edit_template(id), do: Routes.path("#{@base}/templates/#{id}/edit")

  # Projects
  @doc "Projects (non-template) index."
  def projects, do: Routes.path("#{@base}/list")
  @doc "New-project form."
  def new_project, do: Routes.path("#{@base}/list/new")
  @doc "Show page for a single project."
  def project(id), do: Routes.path("#{@base}/list/#{id}")
  @doc "Gantt/waterfall timeline view for a single project."
  def project_gantt(id), do: Routes.path("#{@base}/list/#{id}/gantt")
  @doc "Edit form for a project."
  def edit_project(id), do: Routes.path("#{@base}/list/#{id}/edit")

  # Assignments (within a project)
  @doc "New-assignment form nested under a project."
  def new_assignment(project_id), do: Routes.path("#{@base}/list/#{project_id}/assignments/new")

  @doc "Edit form for an assignment nested under a project."
  def edit_assignment(project_id, id),
    do: Routes.path("#{@base}/list/#{project_id}/assignments/#{id}/edit")
end
