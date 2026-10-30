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

  @doc "Hours across every project the viewer may see."
  @spec hours() :: String.t()
  def hours, do: Routes.path("#{@base}/hours")

  @doc "A project's Hours tab (contributed by the Tasks extension)."
  @spec project_hours(String.t()) :: String.t()
  def project_hours(id), do: Routes.path("#{@base}/#{id}/hours")

  @doc "The Overview — the read-only picture of every project; the last subtab."
  @spec overview() :: String.t()
  def overview, do: Routes.path("#{@base}/overview")

  @doc """
  The Time page — each person's day (or week) across every project the viewer
  may see: what was planned and what was actually done, hour by hour.
  """
  @spec time() :: String.t()
  def time, do: Routes.path("#{@base}/time")

  @doc "Projects → API keys: every key a person has, and what each may do per project."
  def api_keys, do: Routes.path("#{@base}/api-keys")

  @doc "The API keys page with its filters (status, kind, person, project, q) in the query."
  def api_keys_list(params) do
    case URI.encode_query(Enum.reject(params, fn {_k, v} -> v in [nil, ""] end)) do
      "" -> api_keys()
      q -> Routes.path("#{@base}/api-keys?#{q}")
    end
  end

  @doc "The API keys page's Usage tab; `params` (days, key, metric) go in the query."
  def api_keys_usage(params \\ []) do
    case URI.encode_query(Enum.reject(params, fn {_k, v} -> is_nil(v) end)) do
      "" -> Routes.path("#{@base}/api-keys/usage")
      q -> Routes.path("#{@base}/api-keys/usage?#{q}")
    end
  end

  @doc "The API keys page, set to make a new key that starts on `project_uuid`."
  def api_keys(project_uuid), do: Routes.path("#{@base}/api-keys?project=#{project_uuid}")

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
  @typedoc "A project's uuid or key, or the project itself (its key is then used)."
  @type project_ref :: String.t() | map()

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
  @spec project(project_ref()) :: String.t()
  def project(id), do: Routes.path("#{@base}/#{seg(id)}")
  @doc "The Tasks tab of a project (its list view)."
  @spec project_tasks(project_ref()) :: String.t()
  def project_tasks(id), do: Routes.path("#{@base}/#{seg(id)}/tasks")
  @doc "Kanban board view for a single project (inside the Tasks tab)."
  @spec project_board(project_ref()) :: String.t()
  def project_board(id), do: Routes.path("#{@base}/#{seg(id)}/tasks/board")
  @doc "Gantt/waterfall timeline view for a single project (inside the Tasks tab)."
  @spec project_gantt(project_ref()) :: String.t()
  def project_gantt(id), do: Routes.path("#{@base}/#{seg(id)}/tasks/timeline")
  @doc "Month-calendar view for a single project (inside the Tasks tab)."
  @spec project_calendar(project_ref()) :: String.t()
  def project_calendar(id), do: Routes.path("#{@base}/#{seg(id)}/tasks/calendar")
  @doc "The Comments tab of a project."
  @spec project_comments(project_ref()) :: String.t()
  def project_comments(id), do: Routes.path("#{@base}/#{seg(id)}/comments")

  @doc "A project's History tab."
  @spec project_history(project_ref()) :: String.t()
  def project_history(id), do: Routes.path("#{@base}/#{seg(id)}/history")
  @doc "A contributed extension tab of a project, by the tab's key (`\"whiteboards\"`)."
  @spec project_ext_tab(project_ref(), String.t()) :: String.t()
  def project_ext_tab(id, tab_key), do: Routes.path("#{@base}/#{seg(id)}/#{tab_key}")
  @doc "Edit form for a project."
  @spec edit_project(project_ref()) :: String.t()
  def edit_project(id), do: Routes.path("#{@base}/#{seg(id)}/edit")
  @doc "Per-project Modules & Features panel."
  @spec modules(project_ref()) :: String.t()
  def modules(id), do: Routes.path("#{@base}/#{seg(id)}/modules")
  @doc "Per-project Members page."
  @spec members(project_ref()) :: String.t()
  def members(id), do: Routes.path("#{@base}/#{seg(id)}/members")
  @doc "Per-project Your API key page — every member's own keys."
  @spec api(project_ref()) :: String.t()
  def api(id), do: Routes.path("#{@base}/#{seg(id)}/api")
  @doc "Per-project Files page."
  @spec files(project_ref()) :: String.t()
  def files(id), do: Routes.path("#{@base}/#{seg(id)}/files")
  @doc "Per-project Activity page."
  @spec activity(project_ref()) :: String.t()
  def activity(id), do: Routes.path("#{@base}/#{seg(id)}/activity")

  # Assignments (within a project)
  @doc "New-assignment form nested under a project."
  @spec new_assignment(String.t()) :: String.t()
  def new_assignment(project_id), do: Routes.path("#{@base}/#{project_id}/assignments/new")

  @doc "A task's view (read, comment, the next step) nested under a project."
  @spec view_assignment(String.t(), String.t()) :: String.t()
  def view_assignment(project_id, id),
    do: Routes.path("#{@base}/#{project_id}/assignments/#{id}")

  @doc "Edit form for an assignment nested under a project."
  @spec edit_assignment(String.t(), String.t()) :: String.t()
  def edit_assignment(project_id, id),
    do: Routes.path("#{@base}/#{project_id}/assignments/#{id}/edit")

  @doc """
  A link to one task: its project's Tasks tab, naming the task so the page
  scrolls to the row and opens it. With the project's key and the task's
  number in hand it reads `…/ACME/tasks?task=ACME-42`; the fragment is the
  row's DOM id (always the uuid).
  """
  @spec task(project_ref(), map()) :: String.t()
  def task(project, %{uuid: uuid} = assignment) do
    ref =
      case {project, assignment} do
        {%{key: key}, %{number: number}} -> PhoenixKitProjects.Refs.task_ref(key, number)
        _ -> nil
      end

    Routes.path("#{@base}/#{seg(project)}/tasks?task=#{ref || uuid}#task-#{uuid}")
  end

  # A project's URL segment: its key when the caller has the project in
  # hand (`…/projects/ACME`), else whatever id it passed. Both resolve
  # (`Projects.get_project/1`).
  defp seg(%{key: key}) when is_binary(key) and key != "", do: key
  defp seg(%{uuid: uuid}), do: uuid
  defp seg(id) when is_binary(id), do: id
  # A page with no project (not found, a session without an id) still asks
  # for its paths before it redirects.
  defp seg(nil), do: ""
end
