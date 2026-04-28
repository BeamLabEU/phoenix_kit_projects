defmodule PhoenixKitProjects.Projects do
  @moduledoc "Context for projects, tasks, assignments, and dependencies."

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Query

  require Logger

  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Dependency, Project, Task, TaskDependency}

  @typedoc "UUIDv7 string or raw 16-byte binary (Ecto accepts either)."
  @type uuid :: String.t() | <<_::128>>

  @typedoc "Atom-shaped error returned for not-found / missing-resource cases."
  @type error_atom :: :not_found | :template_not_found | :task_not_found

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── Task library ───────────────────────────────────────────────────

  @task_preloads [
    :default_assigned_team,
    :default_assigned_department,
    default_assigned_person: [:user]
  ]

  @doc "Lists all task-library entries, preloaded with defaults."
  @spec list_tasks() :: [Task.t()]
  def list_tasks do
    Task
    |> order_by([t], asc: t.title)
    |> preload(^@task_preloads)
    |> repo().all()
  end

  @doc "Fetches a task by uuid, or `nil` if not found."
  @spec get_task(uuid()) :: Task.t() | nil
  def get_task(uuid) do
    Task |> preload(^@task_preloads) |> repo().get(uuid)
  end

  @doc "Fetches a task by uuid. Raises if not found."
  @spec get_task!(uuid()) :: Task.t()
  def get_task!(uuid) do
    Task |> preload(^@task_preloads) |> repo().get!(uuid)
  end

  @doc "Returns a changeset for the given task."
  @spec change_task(Task.t(), map()) :: Ecto.Changeset.t()
  def change_task(%Task{} = t, attrs \\ %{}), do: Task.changeset(t, attrs)

  @doc "Inserts a task and broadcasts `:task_created`."
  @spec create_task(map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create_task(attrs) do
    with {:ok, task} <- %Task{} |> Task.changeset(attrs) |> repo().insert() do
      ProjectsPubSub.broadcast_task(:task_created, %{uuid: task.uuid, title: task.title})
      {:ok, task}
    end
  end

  @doc "Updates a task and broadcasts `:task_updated`."
  @spec update_task(Task.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def update_task(%Task{} = t, attrs) do
    with {:ok, updated} <- t |> Task.changeset(attrs) |> repo().update() do
      ProjectsPubSub.broadcast_task(:task_updated, %{uuid: updated.uuid, title: updated.title})
      {:ok, updated}
    end
  end

  @doc "Deletes a task and broadcasts `:task_deleted`."
  @spec delete_task(Task.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def delete_task(%Task{} = t) do
    with {:ok, deleted} <- repo().delete(t) do
      ProjectsPubSub.broadcast_task(:task_deleted, %{uuid: deleted.uuid, title: deleted.title})
      {:ok, deleted}
    end
  end

  @doc "Total number of tasks in the library."
  @spec count_tasks() :: non_neg_integer()
  def count_tasks, do: repo().aggregate(Task, :count, :uuid)

  # ── Task template dependencies ─────────────────────────────────

  @doc "Template-level dependencies declared on the given task."
  @spec list_task_dependencies(uuid()) :: [TaskDependency.t()]
  def list_task_dependencies(task_uuid) do
    TaskDependency
    |> where([d], d.task_uuid == ^task_uuid)
    |> preload(:depends_on_task)
    |> repo().all()
  end

  @doc "Adds a template-level dependency from one task to another."
  @spec add_task_dependency(uuid(), uuid()) ::
          {:ok, TaskDependency.t()} | {:error, Ecto.Changeset.t()}
  def add_task_dependency(task_uuid, depends_on_task_uuid) do
    %TaskDependency{}
    |> TaskDependency.changeset(%{
      task_uuid: task_uuid,
      depends_on_task_uuid: depends_on_task_uuid
    })
    |> repo().insert()
  end

  @doc "Removes a template-level dependency. Returns `{:error, :not_found}` if missing."
  @spec remove_task_dependency(uuid(), uuid()) ::
          {:ok, TaskDependency.t()}
          | {:error, :not_found | Ecto.Changeset.t()}
  def remove_task_dependency(task_uuid, depends_on_task_uuid) do
    case repo().get_by(TaskDependency,
           task_uuid: task_uuid,
           depends_on_task_uuid: depends_on_task_uuid
         ) do
      nil -> {:error, :not_found}
      dep -> repo().delete(dep)
    end
  end

  @doc "Tasks that the given task does not yet depend on (for the dependency picker)."
  @spec available_task_dependencies(uuid()) :: [Task.t()]
  def available_task_dependencies(task_uuid) do
    existing =
      from(d in TaskDependency, where: d.task_uuid == ^task_uuid, select: d.depends_on_task_uuid)

    from(t in Task,
      where: t.uuid != ^task_uuid and t.uuid not in subquery(existing),
      order_by: [asc: t.title]
    )
    |> repo().all()
  end

  defp duplicate_constraint?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_, {_, opts}} -> Keyword.get(opts, :constraint) == :unique end)
  end

  @doc """
  When an assignment is created, auto-create assignment-level dependencies
  from the task template's defaults (linking to sibling assignments already
  in the same project).

  Idempotent: duplicate `(assignment_uuid, depends_on_uuid)` pairs return
  a unique-constraint changeset, which we translate into a no-op (already
  exists is the desired end state). All inserts run in a single
  transaction so a partial failure rolls the batch back.
  """
  @spec apply_template_dependencies(Assignment.t()) ::
          :ok | {:ok, term()} | {:error, term()}
  def apply_template_dependencies(assignment) do
    case template_dep_targets(assignment) do
      [] ->
        :ok

      targets ->
        repo().transaction(fn -> Enum.each(targets, &add_template_dep_in_tx(assignment, &1)) end)
    end
  end

  defp template_dep_targets(assignment) do
    template_task_uuids =
      TaskDependency
      |> where([d], d.task_uuid == ^assignment.task_uuid)
      |> select([d], d.depends_on_task_uuid)
      |> repo().all()

    if template_task_uuids == [] do
      []
    else
      from(a in Assignment,
        where:
          a.project_uuid == ^assignment.project_uuid and
            a.task_uuid in ^template_task_uuids and
            a.uuid != ^assignment.uuid,
        select: a.uuid
      )
      |> repo().all()
    end
  end

  defp add_template_dep_in_tx(assignment, dep_assignment_uuid) do
    case add_dependency(assignment.uuid, dep_assignment_uuid) do
      {:ok, _} ->
        :ok

      # Duplicate pair is fine — the unique constraint already enforces it.
      {:error, %Ecto.Changeset{} = cs} ->
        if duplicate_constraint?(cs), do: :ok, else: repo().rollback(cs)
    end
  end

  # ── Projects ───────────────────────────────────────────────────────

  @doc "Lists projects. Accepts `:status` filter and `:include_templates` (default false)."
  @spec list_projects(keyword()) :: [Project.t()]
  def list_projects(opts \\ []) do
    status = Keyword.get(opts, :status)
    include_templates = Keyword.get(opts, :include_templates, false)

    Project
    |> maybe_exclude_templates(include_templates)
    |> maybe_filter_project_status(status)
    |> order_by([p], asc: fragment("lower(?)", p.name), asc: p.uuid)
    |> repo().all()
  end

  defp maybe_exclude_templates(q, true), do: q
  defp maybe_exclude_templates(q, _), do: where(q, [p], p.is_template == false)

  defp maybe_filter_project_status(q, nil), do: q
  defp maybe_filter_project_status(q, ""), do: q
  defp maybe_filter_project_status(q, s), do: where(q, [p], p.status == ^s)

  @doc "Fetches a project by uuid, or `nil` if not found."
  @spec get_project(uuid()) :: Project.t() | nil
  def get_project(uuid), do: repo().get(Project, uuid)
  @doc "Fetches a project by uuid. Raises if not found."
  @spec get_project!(uuid()) :: Project.t()
  def get_project!(uuid), do: repo().get!(Project, uuid)
  @doc "Returns a changeset for the given project."
  @spec change_project(Project.t(), map()) :: Ecto.Changeset.t()
  def change_project(%Project{} = p, attrs \\ %{}), do: Project.changeset(p, attrs)

  @doc "Inserts a project and broadcasts `:project_created`."
  @spec create_project(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(attrs) do
    with {:ok, project} <- %Project{} |> Project.changeset(attrs) |> repo().insert() do
      ProjectsPubSub.broadcast_project(:project_created, project_payload(project))
      {:ok, project}
    end
  end

  @doc "Updates a project and broadcasts `:project_updated`."
  @spec update_project(Project.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def update_project(%Project{} = p, attrs) do
    with {:ok, updated} <- p |> Project.changeset(attrs) |> repo().update() do
      ProjectsPubSub.broadcast_project(:project_updated, project_payload(updated))
      {:ok, updated}
    end
  end

  @doc "Deletes a project and broadcasts `:project_deleted`."
  @spec delete_project(Project.t()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def delete_project(%Project{} = p) do
    with {:ok, deleted} <- repo().delete(p) do
      ProjectsPubSub.broadcast_project(:project_deleted, project_payload(deleted))
      {:ok, deleted}
    end
  end

  defp project_payload(p) do
    %{uuid: p.uuid, name: p.name, is_template: p.is_template, status: p.status}
  end

  @doc "Total number of projects (including templates)."
  @spec count_projects() :: non_neg_integer()
  def count_projects, do: repo().aggregate(Project, :count, :uuid)

  @doc "Lists projects that are templates, ordered by name."
  @spec list_templates() :: [Project.t()]
  def list_templates do
    Project
    |> where([p], p.is_template == true)
    |> order_by([p], asc: fragment("lower(?)", p.name), asc: p.uuid)
    |> repo().all()
  end

  @doc "Total number of template projects."
  @spec count_templates() :: non_neg_integer()
  def count_templates do
    Project
    |> where([p], p.is_template == true)
    |> repo().aggregate(:count, :uuid)
  end

  @doc "Active, in-flight projects (started but not yet completed)."
  @spec list_active_projects() :: [Project.t()]
  def list_active_projects do
    Project
    |> where(
      [p],
      p.is_template == false and p.status == "active" and not is_nil(p.started_at) and
        is_nil(p.completed_at)
    )
    |> order_by([p], desc: p.started_at)
    |> repo().all()
  end

  @doc "Completed projects (all tasks done), most recently completed first."
  @spec list_recently_completed_projects(pos_integer()) :: [Project.t()]
  def list_recently_completed_projects(limit \\ 5) do
    Project
    |> where(
      [p],
      p.is_template == false and p.status == "active" and not is_nil(p.completed_at)
    )
    |> order_by([p], desc: p.completed_at)
    |> limit(^limit)
    |> repo().all()
  end

  @doc "Scheduled projects waiting to start."
  @spec list_upcoming_projects() :: [Project.t()]
  def list_upcoming_projects do
    Project
    |> where(
      [p],
      p.is_template == false and p.status == "active" and is_nil(p.started_at) and
        p.start_mode == "scheduled" and not is_nil(p.scheduled_start_date)
    )
    |> order_by([p], asc: p.scheduled_start_date)
    |> repo().all()
  end

  @doc "Projects not yet started, in setup (immediate mode, not scheduled)."
  @spec list_setup_projects() :: [Project.t()]
  def list_setup_projects do
    Project
    |> where(
      [p],
      p.is_template == false and p.status == "active" and is_nil(p.started_at) and
        p.start_mode == "immediate"
    )
    |> order_by([p], desc: p.inserted_at)
    |> repo().all()
  end

  @doc """
  Counts of assignments by status across active non-template projects.
  Returns a map like %{"todo" => 5, "in_progress" => 2, "done" => 10}.

  Filters on `p.status == "active"` to match the dashboard's intent —
  assignments inside archived projects shouldn't inflate the workload
  stats shown alongside `list_active_projects/0`.
  """
  @spec assignment_status_counts() :: %{optional(String.t()) => non_neg_integer()}
  def assignment_status_counts do
    from(a in Assignment,
      join: p in Project,
      on: p.uuid == a.project_uuid,
      where: p.is_template == false and p.status == "active",
      group_by: a.status,
      select: {a.status, count(a.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc """
  Assignments currently assigned to the given user's staff record.
  Returns non-done assignments across all active projects, with project preloaded.

  The `rescue [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError]`
  block at the bottom is **intentional**: a hard dep on
  `phoenix_kit_staff` means a Staff outage (missing tables in early
  install, sandbox-shutdown in tests, transient connection drop) would
  otherwise take the Projects dashboard down. The rescue degrades
  gracefully to "no assignments for this user" — the dashboard keeps
  rendering for everyone else's data. Don't "clean it up" by
  narrowing or removing.
  """
  @spec list_assignments_for_user(uuid()) :: [Assignment.t()]
  def list_assignments_for_user(user_uuid) do
    case PhoenixKitStaff.Staff.get_person_by_user_uuid(user_uuid, preload: []) do
      nil ->
        []

      person ->
        from(a in Assignment,
          join: p in Project,
          on: p.uuid == a.project_uuid,
          where:
            a.assigned_person_uuid == ^person.uuid and a.status != "done" and
              p.is_template == false and p.status == "active",
          order_by: [asc: a.status, asc: a.inserted_at],
          preload: [:task, :project]
        )
        |> repo().all()
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning(
        "[Projects] staff lookup failed for user #{user_uuid}: #{Exception.message(e)}"
      )

      []
  end

  @doc """
  Summary of an active project for the overview dashboard.
  Returns a map with progress stats.
  """
  @spec project_summary(Project.t()) :: map() | nil
  def project_summary(%Project{} = project) do
    project |> List.wrap() |> project_summaries() |> List.first()
  end

  @doc """
  Batched summaries for many projects — loads all their assignments in
  one query, then groups in memory. Preserves the input project order.
  """
  @spec project_summaries([Project.t()]) :: [map()]
  def project_summaries([]), do: []

  def project_summaries(projects) do
    uuids = Enum.map(projects, & &1.uuid)

    counts_by_project =
      from(a in Assignment,
        where: a.project_uuid in ^uuids,
        group_by: [a.project_uuid, a.status],
        select: {a.project_uuid, a.status, count(a.uuid)}
      )
      |> repo().all()
      |> Enum.reduce(%{}, fn {project_uuid, status, n}, acc ->
        Map.update(acc, project_uuid, %{status => n}, fn inner ->
          Map.put(inner, status, n)
        end)
      end)

    Enum.map(projects, fn p ->
      c = Map.get(counts_by_project, p.uuid, %{})
      done = Map.get(c, "done", 0)
      in_progress = Map.get(c, "in_progress", 0)
      todo = Map.get(c, "todo", 0)
      total = done + in_progress + todo

      %{
        project: p,
        total: total,
        done: done,
        in_progress: in_progress,
        progress_pct: if(total > 0, do: round(done / total * 100), else: 0)
      }
    end)
  end

  @doc """
  Creates a new project by cloning a template. Copies all assignments
  (with their task links, descriptions, durations, assignees, weekends
  settings) and re-creates dependencies between the cloned assignments.
  """
  @spec create_project_from_template(uuid(), map()) ::
          {:ok, Project.t()}
          | {:error, :template_not_found | Ecto.Changeset.t() | term()}
  def create_project_from_template(template_uuid, project_attrs) do
    case get_project(template_uuid) do
      nil -> {:error, :template_not_found}
      template -> clone_template(template, project_attrs)
    end
  end

  defp clone_template(template, project_attrs) do
    attrs =
      Map.merge(project_attrs, %{
        "is_template" => "false",
        "counts_weekends" => to_string(template.counts_weekends)
      })

    template_assignments = list_assignments(template.uuid)
    template_deps = list_all_dependencies(template.uuid)

    repo().transaction(fn ->
      project = create_project_in_tx(attrs)
      uuid_map = clone_assignments_in_tx(template_assignments, project)
      clone_dependencies_in_tx(template_deps, uuid_map)
      project
    end)
  end

  defp create_project_in_tx(attrs) do
    case create_project(attrs) do
      {:ok, project} -> project
      {:error, cs} -> repo().rollback(cs)
    end
  end

  defp clone_assignments_in_tx(template_assignments, project) do
    Enum.reduce(template_assignments, %{}, fn a, acc ->
      case create_assignment(%{
             "project_uuid" => project.uuid,
             "task_uuid" => a.task_uuid,
             "status" => "todo",
             "position" => a.position,
             "description" => a.description,
             "estimated_duration" => a.estimated_duration,
             "estimated_duration_unit" => a.estimated_duration_unit,
             "counts_weekends" => a.counts_weekends,
             "assigned_team_uuid" => a.assigned_team_uuid,
             "assigned_department_uuid" => a.assigned_department_uuid,
             "assigned_person_uuid" => a.assigned_person_uuid
           }) do
        {:ok, new_a} ->
          Map.put(acc, a.uuid, new_a.uuid)

        {:error, cs} ->
          repo().rollback(cs)
      end
    end)
  end

  defp clone_dependencies_in_tx(template_deps, uuid_map) do
    for dep <- template_deps,
        new_a = Map.get(uuid_map, dep.assignment_uuid),
        new_dep = Map.get(uuid_map, dep.depends_on_uuid),
        new_a && new_dep do
      clone_one_dependency_in_tx(new_a, new_dep)
    end
  end

  defp clone_one_dependency_in_tx(assignment_uuid, depends_on_uuid) do
    case add_dependency(assignment_uuid, depends_on_uuid) do
      {:ok, _} -> :ok
      {:error, cs} -> repo().rollback(cs)
    end
  end

  @doc "Stamps `started_at` on the project and broadcasts `:project_started`."
  @spec start_project(Project.t()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def start_project(%Project{} = p) do
    with {:ok, updated} <-
           p |> Project.changeset(%{started_at: DateTime.utc_now()}) |> repo().update() do
      ProjectsPubSub.broadcast_project(:project_started, project_payload(updated))
      {:ok, updated}
    end
  end

  @doc """
  Called after an assignment status change. Checks whether all assignments
  in the project are done. If so, sets `completed_at`. If not (e.g., a task
  was reopened), clears it. Returns the (possibly updated) project.
  """
  @spec recompute_project_completion(uuid()) ::
          :ok
          | {:completed, Project.t()}
          | {:reopened, Project.t()}
          | {:unchanged, Project.t()}
          | {:error, term()}
  def recompute_project_completion(project_uuid) do
    # Wrap the read + check + update in a transaction so two concurrent
    # status changes (e.g. task A marked done, task B reopened) can't
    # both observe the same pre-update state and try to mark the project
    # completed twice. The second wins-or-loses but it's idempotent —
    # broadcast and audit-row consumers see exactly one transition.
    repo().transaction(fn ->
      case get_project(project_uuid) do
        nil -> :ok
        %Project{is_template: true} -> :ok
        project -> decide_completion(project)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _} = err -> err
    end
  end

  defp decide_completion(project) do
    assignments = list_assignments(project.uuid)
    total = length(assignments)
    done = Enum.count(assignments, &(&1.status == "done"))

    cond do
      total > 0 and done == total and project.completed_at == nil ->
        mark_completed(project)

      done != total and project.completed_at != nil ->
        mark_reopened(project)

      true ->
        {:unchanged, project}
    end
  end

  defp mark_completed(project) do
    case project |> Project.changeset(%{completed_at: DateTime.utc_now()}) |> repo().update() do
      {:ok, updated} ->
        ProjectsPubSub.broadcast_project(:project_completed, project_payload(updated))
        {:completed, updated}

      other ->
        other
    end
  end

  defp mark_reopened(project) do
    case project |> Project.changeset(%{completed_at: nil}) |> repo().update() do
      {:ok, updated} ->
        ProjectsPubSub.broadcast_project(:project_reopened, project_payload(updated))
        {:reopened, updated}

      other ->
        other
    end
  end

  # ── Assignments ────────────────────────────────────────────────────

  @assignment_preloads [
    :task,
    :assigned_team,
    :assigned_department,
    :completed_by,
    assigned_person: [:user]
  ]

  @doc "Lists assignments within a project, ordered by position, with related records preloaded."
  @spec list_assignments(uuid()) :: [Assignment.t()]
  def list_assignments(project_uuid) do
    Assignment
    |> where([a], a.project_uuid == ^project_uuid)
    |> order_by([a], asc: a.position, asc: a.inserted_at)
    |> preload(^@assignment_preloads)
    |> repo().all()
  end

  @doc "Fetches an assignment by uuid with related records preloaded, or `nil` if not found."
  @spec get_assignment(uuid()) :: Assignment.t() | nil
  def get_assignment(uuid) do
    Assignment
    |> preload(^@assignment_preloads)
    |> repo().get(uuid)
  end

  @doc "Returns a changeset for the given assignment."
  @spec change_assignment(Assignment.t(), map()) :: Ecto.Changeset.t()
  def change_assignment(%Assignment{} = a, attrs \\ %{}), do: Assignment.changeset(a, attrs)

  @doc "Inserts an assignment and broadcasts `:assignment_created`."
  @spec create_assignment(map()) :: {:ok, Assignment.t()} | {:error, Ecto.Changeset.t()}
  def create_assignment(attrs) do
    with {:ok, a} <- %Assignment{} |> Assignment.changeset(attrs) |> repo().insert() do
      ProjectsPubSub.broadcast_assignment(:assignment_created, %{
        uuid: a.uuid,
        project_uuid: a.project_uuid
      })

      {:ok, a}
    end
  end

  @doc """
  Creates an assignment pre-populated from the task template's defaults
  (description, duration, default assignee). The caller's attrs override
  any template values.
  """
  @spec create_assignment_from_template(uuid(), map()) ::
          {:ok, Assignment.t()} | {:error, :task_not_found | Ecto.Changeset.t()}
  def create_assignment_from_template(task_uuid, attrs) do
    case get_task(task_uuid) do
      nil ->
        {:error, :task_not_found}

      task ->
        defaults = %{
          "task_uuid" => task.uuid,
          "description" => task.description,
          "estimated_duration" => task.estimated_duration,
          "estimated_duration_unit" => task.estimated_duration_unit,
          "assigned_team_uuid" => task.default_assigned_team_uuid,
          "assigned_department_uuid" => task.default_assigned_department_uuid,
          "assigned_person_uuid" => task.default_assigned_person_uuid
        }

        merged = Map.merge(defaults, drop_blanks(attrs))
        create_assignment(merged)
    end
  end

  defp drop_blanks(map) do
    map
    |> Enum.reject(fn {_k, v} -> v == "" or v == nil end)
    |> Map.new()
  end

  @doc """
  Form-safe update for user-submitted attrs. Does NOT apply completion
  fields (`completed_by_uuid`, `completed_at`) even if they appear in
  `attrs` — they are silently dropped by `Assignment.changeset/2`.

  Use `update_assignment_status/2` instead when updating from server
  code that legitimately owns those fields (completion transitions,
  progress updates).

  The `_form` suffix is a deliberate smell: if you reach for this
  function, double-check whether your caller is really a form handler.
  """
  @spec update_assignment_form(Assignment.t(), map()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t()}
  def update_assignment_form(%Assignment{} = a, attrs) do
    with {:ok, updated} <- a |> Assignment.changeset(attrs) |> repo().update() do
      ProjectsPubSub.broadcast_assignment(:assignment_updated, %{
        uuid: updated.uuid,
        project_uuid: updated.project_uuid
      })

      {:ok, updated}
    end
  end

  @doc """
  Server-trusted update that additionally casts `completed_by_uuid` and
  `completed_at`. Only call from server code (never pass raw form attrs),
  since the caller vouches for those fields.
  """
  @spec update_assignment_status(Assignment.t(), map()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t()}
  def update_assignment_status(%Assignment{} = a, attrs) do
    with {:ok, updated} <- a |> Assignment.status_changeset(attrs) |> repo().update() do
      ProjectsPubSub.broadcast_assignment(:assignment_updated, %{
        uuid: updated.uuid,
        project_uuid: updated.project_uuid
      })

      {:ok, updated}
    end
  end

  @doc "Deletes an assignment and broadcasts `:assignment_deleted`."
  @spec delete_assignment(Assignment.t()) :: {:ok, Assignment.t()} | {:error, Ecto.Changeset.t()}
  def delete_assignment(%Assignment{} = a) do
    with {:ok, deleted} <- repo().delete(a) do
      ProjectsPubSub.broadcast_assignment(:assignment_deleted, %{
        uuid: deleted.uuid,
        project_uuid: deleted.project_uuid
      })

      {:ok, deleted}
    end
  end

  @doc "Marks an assignment done, stamping `completed_by_uuid` and `completed_at`."
  @spec complete_assignment(Assignment.t(), uuid() | nil) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t()}
  def complete_assignment(%Assignment{} = a, completed_by_uuid) do
    update_assignment_status(a, %{
      status: "done",
      completed_by_uuid: completed_by_uuid,
      completed_at: DateTime.utc_now()
    })
  end

  @doc "Reverts an assignment to `todo` and clears its completion fields."
  @spec reopen_assignment(Assignment.t()) :: {:ok, Assignment.t()} | {:error, Ecto.Changeset.t()}
  def reopen_assignment(%Assignment{} = a) do
    update_assignment_status(a, %{
      status: "todo",
      completed_by_uuid: nil,
      completed_at: nil
    })
  end

  # ── Dependencies ───────────────────────────────────────────────────

  @doc "Dependencies declared on a single assignment."
  @spec list_dependencies(uuid()) :: [Dependency.t()]
  def list_dependencies(assignment_uuid) do
    Dependency
    |> where([d], d.assignment_uuid == ^assignment_uuid)
    |> preload(depends_on: [:task])
    |> repo().all()
  end

  @doc "All dependencies across every assignment in a project (used when cloning templates)."
  @spec list_all_dependencies(uuid()) :: [Dependency.t()]
  def list_all_dependencies(project_uuid) do
    from(d in Dependency,
      join: a in Assignment,
      on: d.assignment_uuid == a.uuid,
      where: a.project_uuid == ^project_uuid,
      preload: [depends_on: [:task]]
    )
    |> repo().all()
  end

  @doc """
  Adds an assignment-level dependency and broadcasts `:dependency_added`.

  Rejects any edge that would introduce a cycle — i.e., if `depends_on_uuid`
  already (transitively) depends on `assignment_uuid`, the insert is
  refused with a changeset error. The schema-level self-reference check
  handles the `A == B` case; this function handles multi-hop cycles
  (`A → B`, then `B → A`).

  The cycle check + insert run inside a `:serializable` transaction.
  Without this, two concurrent calls — `add_dependency(A, B)` and
  `add_dependency(B, A)` — could each read an acyclic graph, both
  pass the check, both insert, and produce a cycle (the unique pair
  index doesn't catch this; it only rejects identical duplicate
  edges). At `:serializable` Postgres aborts the loser with
  `serialization_failure` (`SQLSTATE 40001`); we catch that and
  return a friendly changeset error so the caller can retry.
  """
  @spec add_dependency(uuid(), uuid()) ::
          {:ok, Dependency.t()} | {:error, Ecto.Changeset.t()}
  def add_dependency(assignment_uuid, depends_on_uuid) do
    changeset =
      Dependency.changeset(%Dependency{}, %{
        assignment_uuid: assignment_uuid,
        depends_on_uuid: depends_on_uuid
      })

    if changeset.valid? do
      do_add_dependency_in_serializable_tx(assignment_uuid, depends_on_uuid, changeset)
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  defp do_add_dependency_in_serializable_tx(assignment_uuid, depends_on_uuid, changeset) do
    result =
      repo().transaction(
        fn ->
          if would_create_cycle?(assignment_uuid, depends_on_uuid) do
            cs =
              Ecto.Changeset.add_error(
                changeset,
                :depends_on_uuid,
                gettext("would create a dependency cycle")
              )

            repo().rollback(%{cs | action: :insert})
          else
            case repo().insert(changeset) do
              {:ok, dep} -> dep
              {:error, cs} -> repo().rollback(cs)
            end
          end
        end,
        isolation: :serializable
      )

    case result do
      {:ok, dep} ->
        broadcast_dep(dep, :dependency_added)
        {:ok, dep}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, cs}
    end
  rescue
    e in Postgrex.Error ->
      if Map.get(e.postgres || %{}, :code) == :serialization_failure do
        cs =
          Ecto.Changeset.add_error(
            changeset,
            :depends_on_uuid,
            gettext("conflicting dependency change in flight, please retry")
          )

        {:error, %{cs | action: :insert}}
      else
        reraise e, __STACKTRACE__
      end
  end

  # Returns true when `depends_on_uuid` already reaches `assignment_uuid`
  # transitively — inserting the new edge would close a cycle.
  defp would_create_cycle?(assignment_uuid, depends_on_uuid) do
    walk_dependencies([depends_on_uuid], %{}, assignment_uuid)
  end

  @spec walk_dependencies([binary()], %{binary() => true}, binary()) :: boolean()
  defp walk_dependencies([], _seen, _target), do: false

  defp walk_dependencies([current | rest], seen, target) do
    cond do
      current == target ->
        true

      Map.has_key?(seen, current) ->
        walk_dependencies(rest, seen, target)

      true ->
        next =
          Dependency
          |> where([d], d.assignment_uuid == ^current)
          |> select([d], d.depends_on_uuid)
          |> repo().all()

        walk_dependencies(next ++ rest, Map.put(seen, current, true), target)
    end
  end

  @doc "Removes an assignment-level dependency and broadcasts `:dependency_removed`."
  @spec remove_dependency(uuid(), uuid()) ::
          {:ok, Dependency.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def remove_dependency(assignment_uuid, depends_on_uuid) do
    case repo().get_by(Dependency,
           assignment_uuid: assignment_uuid,
           depends_on_uuid: depends_on_uuid
         ) do
      nil ->
        {:error, :not_found}

      dep ->
        with {:ok, deleted} <- repo().delete(dep) do
          broadcast_dep(deleted, :dependency_removed)
          {:ok, deleted}
        end
    end
  end

  defp broadcast_dep(dep, event) do
    case repo().get(Assignment, dep.assignment_uuid) do
      nil ->
        :ok

      a ->
        ProjectsPubSub.broadcast_dependency(event, %{
          assignment_uuid: dep.assignment_uuid,
          depends_on_uuid: dep.depends_on_uuid,
          project_uuid: a.project_uuid
        })
    end
  end

  @doc "Assignments in this project that the given assignment does NOT yet depend on."
  @spec available_dependencies(uuid(), uuid()) :: [Assignment.t()]
  def available_dependencies(project_uuid, assignment_uuid) do
    existing =
      from(d in Dependency,
        where: d.assignment_uuid == ^assignment_uuid,
        select: d.depends_on_uuid
      )

    from(a in Assignment,
      where:
        a.project_uuid == ^project_uuid and
          a.uuid != ^assignment_uuid and
          a.uuid not in subquery(existing),
      preload: [:task],
      order_by: [asc: a.position, asc: a.inserted_at]
    )
    |> repo().all()
  end

  @doc "Check if all dependencies of an assignment are done."
  @spec dependencies_met?(uuid()) :: boolean()
  def dependencies_met?(assignment_uuid) do
    from(d in Dependency,
      join: dep_on in Assignment,
      on: d.depends_on_uuid == dep_on.uuid,
      where: d.assignment_uuid == ^assignment_uuid and dep_on.status != "done"
    )
    |> repo().aggregate(:count, :uuid) == 0
  end
end
