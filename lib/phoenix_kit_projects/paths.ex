defmodule PhoenixKitProjects.Paths do
  @moduledoc "Centralized path helpers for the Projects module."

  alias PhoenixKit.Utils.Routes

  @base "/admin/projects"

  @doc """
  The module's landing page — the project list (since 2026-09; it used to be
  the Overview). Same value as `projects/0`.
  """
  @spec index() :: String.t()
  def index, do: Routes.path(@base)

  @doc "The Overview — the read-only picture of every project; the last subtab."
  @spec overview() :: String.t()
  def overview, do: Routes.path("#{@base}/overview")

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
  @doc """
  Projects (non-template) index — the landing page. Project pages sit
  directly under it (`#{@base}/:id/…`); the pre-2026-09 `#{@base}/list/…`
  addresses redirect to the same paths without the segment.
  """
  @spec projects() :: String.t()
  def projects, do: Routes.path(@base)
  @doc "New-project form."
  @spec new_project() :: String.t()
  def new_project, do: Routes.path("#{@base}/new")
  @doc "Show page for a single project."
  @spec project(String.t()) :: String.t()
  def project(id), do: Routes.path("#{@base}/#{id}")
  @doc "The Tasks tab of a project (its list view)."
  @spec project_tasks(String.t()) :: String.t()
  def project_tasks(id), do: Routes.path("#{@base}/#{id}/tasks")
  @doc "Kanban board view for a single project (inside the Tasks tab)."
  @spec project_board(String.t()) :: String.t()
  def project_board(id), do: Routes.path("#{@base}/#{id}/tasks/board")
  @doc "Gantt/waterfall timeline view for a single project (inside the Tasks tab)."
  @spec project_gantt(String.t()) :: String.t()
  def project_gantt(id), do: Routes.path("#{@base}/#{id}/tasks/timeline")
  @doc "Month-calendar view for a single project (inside the Tasks tab)."
  @spec project_calendar(String.t()) :: String.t()
  def project_calendar(id), do: Routes.path("#{@base}/#{id}/tasks/calendar")
  @doc "The Comments tab of a project."
  @spec project_comments(String.t()) :: String.t()
  def project_comments(id), do: Routes.path("#{@base}/#{id}/comments")
  @doc "A contributed extension tab of a project, by the tab's key (`\"whiteboards\"`)."
  @spec project_ext_tab(String.t(), String.t()) :: String.t()
  def project_ext_tab(id, tab_key), do: Routes.path("#{@base}/#{id}/#{tab_key}")
  @doc "Edit form for a project."
  @spec edit_project(String.t()) :: String.t()
  def edit_project(id), do: Routes.path("#{@base}/#{id}/edit")
  @doc "Per-project Modules & Features panel."
  @spec modules(String.t()) :: String.t()
  def modules(id), do: Routes.path("#{@base}/#{id}/modules")
  @doc "Per-project Members page."
  @spec members(String.t()) :: String.t()
  def members(id), do: Routes.path("#{@base}/#{id}/members")
  @doc "Per-project Files page."
  @spec files(String.t()) :: String.t()
  def files(id), do: Routes.path("#{@base}/#{id}/files")
  @doc "Per-project Activity page."
  @spec activity(String.t()) :: String.t()
  def activity(id), do: Routes.path("#{@base}/#{id}/activity")

  # Assignments (within a project)
  @doc "New-assignment form nested under a project."
  @spec new_assignment(String.t()) :: String.t()
  def new_assignment(project_id), do: Routes.path("#{@base}/#{project_id}/assignments/new")

  @doc "Edit form for an assignment nested under a project."
  @spec edit_assignment(String.t(), String.t()) :: String.t()
  def edit_assignment(project_id, id),
    do: Routes.path("#{@base}/#{project_id}/assignments/#{id}/edit")
end
