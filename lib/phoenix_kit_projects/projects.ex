defmodule PhoenixKitProjects.Projects do
  @moduledoc "Context for projects, tasks, assignments, and dependencies."

  use Gettext, backend: PhoenixKitProjects.Gettext

  import Ecto.Query

  require Logger

  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Dependency, Project, Task, TaskDependency}

  # Dialyzer loses opacity on `MapSet.t()` whenever an empty MapSet
  # (`MapSet.new()` — `%MapSet{map: %{}}`) seeds a recursive helper
  # whose spec is `MapSet.t()` (`%MapSet{map: internal(value)}`).
  # The empty literal isn't a member of the opaque internal type until
  # something has been inserted. The standard-lib functions are used
  # correctly; the warning is a false positive. Suppress at both the
  # callee (the recursive helpers) and the caller (the public fns that
  # seed `MapSet.new()`) — dialyzer attributes `call_without_opaque`
  # to the caller, not the called fn.
  @dialyzer {:no_opaque,
             [
               build_group_tree: 4,
               build_closure_tree: 3,
               list_task_groups: 0,
               task_closure: 2
             ]}

  @typedoc "UUIDv7 string or raw 16-byte binary (Ecto accepts either)."
  @type uuid :: String.t() | <<_::128>>

  @typedoc "Atom-shaped error returned for not-found / missing-resource cases."
  @type error_atom :: :not_found | :template_not_found | :task_not_found

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # Max number of uuids accepted in one reorder call. Compile-env
  # overridable; the default mirrors `phoenix_kit_catalogue`'s cap so
  # any list view that needs a bigger payload signals intent rather
  # than silently exceeding it. Beyond the cap we want to switch to a
  # paged / virtualised approach instead.
  @reorder_max_uuids Application.compile_env(:phoenix_kit_projects, :reorder_max_uuids, 1000)

  # Last-write-wins dedup on a uuid list. Catalogue ships an identical
  # helper (`Helpers.dedupe_keep_last/1`) — repeating the few lines
  # here keeps `phoenix_kit_projects` independent of catalogue and
  # documents the contract: order preserved, last occurrence kept.
  defp dedupe_uuids(uuids) when is_list(uuids) do
    {result, _seen} =
      uuids
      |> Enum.reverse()
      |> Enum.reduce({[], MapSet.new()}, fn uuid, {acc, seen} ->
        if MapSet.member?(seen, uuid),
          do: {acc, seen},
          else: {[uuid | acc], MapSet.put(seen, uuid)}
      end)

    result
  end

  # ── Task library ───────────────────────────────────────────────────

  @task_preloads [
    :default_assigned_team,
    :default_assigned_department,
    default_assigned_person: [:user]
  ]

  @doc """
  Lists all task-library entries, preloaded with defaults.

  Order: `position ASC, inserted_at ASC`. Date-added is the secondary
  sort (NOT title) so renaming a task doesn't shuffle it in the list
  — a complaint we got from the boss with the prior `title`-secondary
  ordering. After a reorder, dragged tasks claim `1..N` and appear
  above any still-zero ones; among the still-zero tasks, creation
  order wins.
  """
  @spec list_tasks() :: [Task.t()]
  def list_tasks do
    Task
    |> order_by([t], asc: t.position, asc: t.inserted_at)
    |> preload(^@task_preloads)
    |> repo().all()
  end

  @doc """
  Next available `position` for a new task — one past the current
  max, falling back to `1` on an empty table. New tasks should be
  inserted with this value so they land at the bottom of the
  user's manual order.
  """
  @spec next_task_position() :: integer()
  def next_task_position do
    case repo().one(from(t in Task, select: max(t.position))) do
      nil -> 1
      n -> n + 1
    end
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
    # Auto-assign the next position so new tasks land at the end of
    # the manually-reordered library list. Caller-supplied positions
    # win — covers the cloning paths that explicitly set positions.
    attrs = put_default_position(attrs, &next_task_position/0)

    with {:ok, task} <- %Task{} |> Task.changeset(attrs) |> repo().insert() do
      ProjectsPubSub.broadcast_task(:task_created, %{uuid: task.uuid, title: task.title})
      {:ok, task}
    end
  end

  # Inserts `position: <next>` only if the caller didn't already
  # supply one. Accepts string- or atom-keyed maps (Phoenix forms vs
  # programmatic callers).
  defp put_default_position(attrs, next_fn) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, "position") -> attrs
      Map.has_key?(attrs, :position) -> attrs
      true -> Map.put(attrs, "position", next_fn.())
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

  @doc """
  Returns `%{assignment_uuid => published_comment_count}` for the
  given assignment uuids. Single grouped query (no N queries).

  Returns `%{}` if the `phoenix_kit_comments` module isn't loaded
  (host hasn't installed it) or if anything goes wrong at the query
  level — the comments badge is purely informational, never blocking,
  so any failure degrades silently.
  """
  @spec comment_counts_for_assignments([uuid()]) ::
          %{optional(String.t()) => non_neg_integer()}
  def comment_counts_for_assignments([]), do: %{}

  def comment_counts_for_assignments(assignment_uuids) when is_list(assignment_uuids) do
    if Code.ensure_loaded?(PhoenixKitComments.Comment) do
      do_count_assignment_comments(assignment_uuids)
    else
      %{}
    end
  rescue
    # Comments are optional — UndefinedFunctionError covers
    # cross-module Hex skew, Postgrex/Ownership covers DB transients.
    # Anything else surfaces.
    UndefinedFunctionError -> %{}
    Postgrex.Error -> %{}
    DBConnection.OwnershipError -> %{}
  catch
    :exit, _reason -> %{}
  end

  defp do_count_assignment_comments(assignment_uuids) do
    from(c in PhoenixKitComments.Comment,
      where:
        c.resource_type == "assignment" and c.resource_uuid in ^assignment_uuids and
          c.status == "published",
      group_by: c.resource_uuid,
      select: {c.resource_uuid, count(c.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc """
  Re-indexes the supplied task uuids into positions `1..N`. Used by
  the task-library list-view DnD handler.

  No parent scope — the task library is a flat collection. UUIDs not
  found in the table are dropped silently (the LV may have a stale
  view of the page when the user dragged). Duplicates in the input
  list are deduped last-write-wins.

  Two-pass write inside a transaction: pass 1 stamps `position =
  -idx`, pass 2 stamps `position = idx`. Sidesteps any future unique
  index on `position` and stays atomic.

  The `@reorder_max_uuids` cap is checked against the **raw input
  list length**, before dedup — a payload over the cap signals a
  misbehaving client (real users can't drag 1000+ rows in one
  batched event), so the rejection is a guard, not a real-user
  constraint.

  Returns `:ok` on success, `{:error, :too_many_uuids}` past the cap,
  or `{:error, reason}` on a DB failure. Audit rows are written for
  every outcome (success carries the count + first-uuid; rejection
  paths log via `log_reorder_rejected/3` shape).
  """
  @spec reorder_tasks([uuid()], keyword()) ::
          :ok | {:error, :too_many_uuids | term()}
  def reorder_tasks(ordered_uuids, opts \\ [])

  def reorder_tasks(ordered_uuids, opts)
      when is_list(ordered_uuids) and length(ordered_uuids) > @reorder_max_uuids do
    log_reorder_rejected("task", :too_many_uuids, length(ordered_uuids), opts)
    {:error, :too_many_uuids}
  end

  def reorder_tasks(ordered_uuids, opts) when is_list(ordered_uuids) do
    unique_uuids = dedupe_uuids(ordered_uuids)

    case write_task_positions(unique_uuids) do
      {:ok, 0} ->
        # All uuids stale — silent no-op (no audit row); the LV will
        # snap back to persisted state on its next reload.
        :ok

      {:ok, count} ->
        log_reorder_success("task", List.first(unique_uuids), count, opts)
        :ok

      {:error, reason} ->
        log_reorder_db_error("task", unique_uuids, opts)
        {:error, reason}
    end
  end

  defp write_task_positions(unique_uuids) do
    repo().transaction(fn ->
      pairs = Enum.with_index(unique_uuids, 1)

      # Pass 1: stamp negatives so a future unique index on `position`
      # wouldn't collide with the source rows still holding their old
      # values.
      Enum.each(pairs, fn {uuid, idx} ->
        from(t in Task, where: t.uuid == ^uuid)
        |> repo().update_all(set: [position: -idx])
      end)

      # Pass 2: stamp the final positives. `update_all` returns
      # `{count, _}` per row; we sum the second pass to get the true
      # number of rows touched (drops uuids that didn't match the
      # table).
      pairs
      |> Enum.reduce(0, fn {uuid, idx}, total ->
        {n, _} =
          from(t in Task, where: t.uuid == ^uuid)
          |> repo().update_all(set: [position: idx])

        total + n
      end)
    end)
  end

  defp log_reorder_success(kind, first_uuid, count, opts) do
    extra = Keyword.get(opts, :metadata, %{})

    log_activity(%{
      action: "#{kind}.reordered",
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: kind,
      resource_uuid: first_uuid,
      metadata: Map.merge(%{"count" => count}, extra)
    })
  end

  defp log_reorder_rejected(kind, reason, count, opts) do
    log_activity(%{
      action: "#{kind}.reorder_rejected",
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: kind,
      metadata: %{"reason" => to_string(reason), "count" => count}
    })
  end

  defp log_reorder_db_error(kind, uuids, opts) do
    log_activity(%{
      action: "#{kind}.reorder_failed",
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: kind,
      metadata: %{"count" => length(uuids), "uuids" => Enum.take(uuids, 20)}
    })
  end

  # Wraps `PhoenixKit.Activity.log/1` with the same load-bearing
  # rescue + catch shape every other module uses — logging failures
  # never crash the primary operation. Mirror of
  # `PhoenixKitProjects.Activity`'s wrapper but local-only since
  # reorder logging fires from the context layer (not the LV layer
  # where `Activity.log/3` lives).
  defp log_activity(payload) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      try do
        PhoenixKit.Activity.log(Map.put_new(payload, :module, "projects"))
      rescue
        Postgrex.Error -> :ok
        DBConnection.OwnershipError -> :ok
        e -> Logger.warning("[Projects] activity log failed: #{Exception.message(e)}")
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @doc """
  Returns the flat task list with a `%{task_uuid => [Task]}` map of
  the directed `TaskDependency` edges (`task → depends_on_task`) for
  badge rendering. Used by the task-library list view (the default
  view mode).
  """
  @spec list_tasks_with_deps() :: %{
          tasks: [Task.t()],
          deps_by_task: %{optional(String.t()) => [Task.t()]}
        }
  def list_tasks_with_deps do
    tasks = list_tasks()
    %{tasks: tasks, deps_by_task: deps_by_task_map(tasks)}
  end

  @doc """
  Returns task-library "groups" — rooted dependency trees.

  Each group has one root (a task that nothing else depends on,
  i.e. has no incoming `depends_on_task_uuid` edge) plus its full
  transitive closure of task-template deps. Tasks shared across
  multiple roots **appear in each group** — duplication is the point
  of the grouped view: it surfaces "this task is reused across N
  workflows."

  Tasks with no deps either way (no incoming and no outgoing edges)
  are returned in `:standalone` instead of being padded out as
  one-task groups, so the group view doesn't look like 50 tiny cards
  for unrelated singletons.

  Returns `%{trees: [closure_node()], standalone: [Task.t()]}` where
  each `closure_node()` has `:task`, `:children`, `:cycle?`,
  `:already_in_project?` (the last is `false` here — this view isn't
  scoped to a project; the field is kept for shape compatibility with
  `task_closure/2`).
  """
  @spec list_task_groups() :: %{trees: [closure_node()], standalone: [Task.t()]}
  def list_task_groups do
    tasks = list_tasks()
    edges = repo().all(TaskDependency)
    task_by_uuid = Map.new(tasks, &{&1.uuid, &1})

    out_edges = Enum.group_by(edges, & &1.task_uuid, & &1.depends_on_task_uuid)
    has_incoming = MapSet.new(edges, & &1.depends_on_task_uuid)
    has_outgoing = MapSet.new(Map.keys(out_edges))

    {root_uuids, leaf_only_uuids} =
      Enum.split_with(tasks, fn t ->
        # "Root" = no other task depends on it. Includes tasks that
        # themselves have outgoing deps (the typical workflow root).
        not MapSet.member?(has_incoming, t.uuid) and MapSet.member?(has_outgoing, t.uuid)
      end)

    standalone =
      tasks
      |> Enum.reject(fn t ->
        MapSet.member?(has_incoming, t.uuid) or MapSet.member?(has_outgoing, t.uuid)
      end)
      |> Enum.sort_by(& &1.title)

    # Tasks that are only-a-leaf (depended on but no outgoing deps)
    # would never be a root — they show up under their parents.
    _ = leaf_only_uuids

    trees =
      root_uuids
      |> Enum.sort_by(& &1.title)
      |> Enum.map(fn root ->
        build_group_tree(root.uuid, MapSet.new(), task_by_uuid, out_edges)
      end)
      |> Enum.reject(&is_nil/1)

    %{trees: trees, standalone: standalone}
  end

  @spec build_group_tree(uuid(), MapSet.t(), map(), map()) :: closure_node() | nil
  defp build_group_tree(task_uuid, visited, task_by_uuid, out_edges) do
    if MapSet.member?(visited, task_uuid) do
      case Map.get(task_by_uuid, task_uuid) do
        nil -> nil
        task -> %{task: task, children: [], cycle?: true, already_in_project?: false}
      end
    else
      case Map.get(task_by_uuid, task_uuid) do
        nil ->
          nil

        task ->
          next_visited = MapSet.put(visited, task_uuid)
          children_uuids = Map.get(out_edges, task_uuid, [])

          children =
            children_uuids
            |> Enum.sort()
            |> Enum.map(&build_group_tree(&1, next_visited, task_by_uuid, out_edges))
            |> Enum.reject(&is_nil/1)

          %{task: task, children: children, cycle?: false, already_in_project?: false}
      end
    end
  end

  defp deps_by_task_map(tasks) do
    edges = repo().all(TaskDependency)
    task_by_uuid = Map.new(tasks, &{&1.uuid, &1})

    edges
    |> Enum.group_by(& &1.task_uuid, &Map.get(task_by_uuid, &1.depends_on_task_uuid))
    |> Map.new(fn {k, deps} ->
      {k, deps |> Enum.reject(&is_nil/1) |> Enum.sort_by(& &1.title)}
    end)
  end

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

  # ── Task closure (transitive task-template dependencies) ─────────

  @typedoc """
  A node in the task-template dependency closure tree.

  - `:task` — the `Task` schema struct, with task-level preloads.
  - `:children` — child trees (the tasks this one depends on,
    transitively).
  - `:cycle?` — `true` if this node was reached via a cycle in the
    template graph and traversal stopped here. `TaskDependency` doesn't
    enforce acyclicity, so this flag lets the UI render a warning
    instead of spinning forever.
  - `:already_in_project?` — `true` if an assignment for this task
    already exists in the target project. UI uses this to show the
    node as "already there" (won't be re-added on save) — applies to
    every node in the tree, including the root.
  """
  @type closure_node :: %{
          task: Task.t(),
          children: [closure_node()],
          cycle?: boolean(),
          already_in_project?: boolean()
        }

  @doc """
  Builds the task-template dependency closure rooted at `root_task_uuid`.

  Traverses `TaskDependency` edges (`task → depends_on_task`) outward
  from the root, returning a tree the UI can render with checkboxes
  for pruning. `project_uuid` is used to mark which nodes already have
  an assignment in the target project — those are skipped on save
  (the assignment-form's "drag in closure" flow won't duplicate them).

  Returns `nil` if `root_task_uuid` doesn't resolve to a task. Cycles
  in the template graph are detected and short-circuited; the cycle
  node has `cycle?: true` and no children.
  """
  @spec task_closure(uuid(), uuid()) :: closure_node() | nil
  def task_closure(root_task_uuid, project_uuid) do
    in_project = assignment_task_uuid_set(project_uuid)
    build_closure_tree(root_task_uuid, MapSet.new(), in_project)
  end

  @spec build_closure_tree(uuid(), MapSet.t(), MapSet.t()) :: closure_node() | nil
  defp build_closure_tree(task_uuid, visited, in_project) do
    if MapSet.member?(visited, task_uuid) do
      case get_task(task_uuid) do
        nil ->
          nil

        task ->
          %{
            task: task,
            children: [],
            cycle?: true,
            already_in_project?: MapSet.member?(in_project, task_uuid)
          }
      end
    else
      case get_task(task_uuid) do
        nil ->
          nil

        task ->
          next_visited = MapSet.put(visited, task_uuid)
          dep_uuids = list_task_dependency_uuids(task_uuid)

          children =
            dep_uuids
            |> Enum.map(&build_closure_tree(&1, next_visited, in_project))
            |> Enum.reject(&is_nil/1)

          %{
            task: task,
            children: children,
            cycle?: false,
            already_in_project?: MapSet.member?(in_project, task_uuid)
          }
      end
    end
  end

  defp list_task_dependency_uuids(task_uuid) do
    TaskDependency
    |> where([d], d.task_uuid == ^task_uuid)
    |> select([d], d.depends_on_task_uuid)
    |> repo().all()
  end

  defp assignment_task_uuid_set(project_uuid) do
    Assignment
    |> where([a], a.project_uuid == ^project_uuid)
    |> select([a], a.task_uuid)
    |> repo().all()
    |> MapSet.new()
  end

  @doc """
  Flattens a `closure_node()` tree into a `%{task_uuid => %Task{}}` map.

  Used by the save path to enumerate every task that *might* become an
  assignment (before applying the user's exclusions). `Map` rather than
  list because the same task can appear multiple times across branches
  if two parents both depend on it — the map dedups by uuid.
  """
  @spec flatten_closure(closure_node() | nil) :: %{optional(String.t()) => Task.t()}
  def flatten_closure(nil), do: %{}

  def flatten_closure(%{task: task, children: children}) do
    Enum.reduce(children, %{task.uuid => task}, fn child, acc ->
      Map.merge(acc, flatten_closure(child))
    end)
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

  @doc """
  Lists projects.

  Options:
    * `:archived` — `false` (default) hides archived; `true` shows only
      archived; `:all` returns both.
    * `:include_templates` — default `false`.
  """
  @spec list_projects(keyword()) :: [Project.t()]
  def list_projects(opts \\ []) do
    archived = Keyword.get(opts, :archived, false)
    include_templates = Keyword.get(opts, :include_templates, false)

    Project
    |> maybe_exclude_templates(include_templates)
    |> maybe_filter_archived(archived)
    |> order_by([p], asc: p.position, asc: p.inserted_at, asc: p.uuid)
    |> repo().all()
  end

  defp maybe_exclude_templates(q, true), do: q
  defp maybe_exclude_templates(q, _), do: where(q, [p], p.is_template == false)

  defp maybe_filter_archived(q, :all), do: q
  defp maybe_filter_archived(q, true), do: where(q, [p], not is_nil(p.archived_at))
  defp maybe_filter_archived(q, _false_or_nil), do: where(q, [p], is_nil(p.archived_at))

  @doc "Fetches a project by uuid, or `nil` if not found."
  @spec get_project(uuid()) :: Project.t() | nil
  def get_project(uuid), do: repo().get(Project, uuid)
  @doc "Fetches a project by uuid. Raises if not found."
  @spec get_project!(uuid()) :: Project.t()
  def get_project!(uuid), do: repo().get!(Project, uuid)

  @doc """
  Returns a changeset for the given project.

  Accepts the same `opts` as `Project.changeset/3` — notably
  `:enforce_scheduled_date_required`, which the project form passes as
  `false` on `phx-change` events so the just-revealed date input doesn't
  light up red before the user has had a chance to fill it.
  """
  @spec change_project(Project.t(), map(), keyword()) :: Ecto.Changeset.t()
  def change_project(%Project{} = p, attrs \\ %{}, opts \\ []),
    do: Project.changeset(p, attrs, opts)

  @doc "Inserts a project and broadcasts `:project_created`."
  @spec create_project(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(attrs) do
    # Auto-assign the next position scoped to the project's
    # `is_template` bucket so a new row lands at the bottom of either
    # the project list or the template list (whichever the row
    # belongs to). Caller-supplied positions still win; covers the
    # template-clone path and any future bulk insert.
    is_template? = template_attr?(attrs)
    attrs = put_default_position(attrs, fn -> next_project_position(is_template?) end)

    with {:ok, project} <- %Project{} |> Project.changeset(attrs) |> repo().insert() do
      ProjectsPubSub.broadcast_project(:project_created, project_payload(project))
      {:ok, project}
    end
  end

  defp template_attr?(attrs) do
    val = Map.get(attrs, "is_template") || Map.get(attrs, :is_template)
    val in [true, "true", "1", 1, "on"]
  end

  @doc """
  Next available `position` within the given `is_template` scope —
  one past the per-bucket max, falling back to `1` on an empty
  bucket. Projects (`is_template = false`) and templates (`true`)
  share the column but order independently.
  """
  @spec next_project_position(boolean()) :: integer()
  def next_project_position(is_template?) when is_boolean(is_template?) do
    case repo().one(
           from(p in Project, where: p.is_template == ^is_template?, select: max(p.position))
         ) do
      nil -> 1
      n -> n + 1
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
    %{
      uuid: p.uuid,
      name: p.name,
      is_template: p.is_template
    }
  end

  @doc """
  Re-indexes the supplied project uuids into positions `1..N`.
  Used by the project list-view DnD handler.

  Scope: `is_template = false`. UUIDs that resolve to templates (or
  to no row at all) abort the whole batch with
  `{:error, :wrong_scope}`. Duplicates dedup last-write-wins.
  Two-pass write (negatives → positives) inside a transaction.

  The `@reorder_max_uuids` cap is checked against the **raw input
  list length**, before dedup — a payload over the cap signals a
  misbehaving client (real users can't drag 1000+ rows in one
  batched event), so the rejection is a guard, not a real-user
  constraint. Same shape as `reorder_tasks/2`.
  """
  @spec reorder_projects([uuid()], keyword()) ::
          :ok | {:error, :too_many_uuids | :wrong_scope | term()}
  def reorder_projects(ordered_uuids, opts \\ []),
    do: reorder_projects_in_scope(false, "project", ordered_uuids, opts)

  @doc """
  Same as `reorder_projects/2` but scoped to `is_template = true`.
  Audit rows use `template.reordered` so the activity feed
  distinguishes the two.
  """
  @spec reorder_templates([uuid()], keyword()) ::
          :ok | {:error, :too_many_uuids | :wrong_scope | term()}
  def reorder_templates(ordered_uuids, opts \\ []),
    do: reorder_projects_in_scope(true, "template", ordered_uuids, opts)

  defp reorder_projects_in_scope(_is_template, kind, ordered_uuids, opts)
       when is_list(ordered_uuids) and length(ordered_uuids) > @reorder_max_uuids do
    log_reorder_rejected(kind, :too_many_uuids, length(ordered_uuids), opts)
    {:error, :too_many_uuids}
  end

  defp reorder_projects_in_scope(is_template?, kind, ordered_uuids, opts)
       when is_boolean(is_template?) and is_list(ordered_uuids) do
    unique_uuids = dedupe_uuids(ordered_uuids)

    case project_scope_check(is_template?, unique_uuids) do
      :empty ->
        :ok

      :ok ->
        case write_project_positions(unique_uuids) do
          {:ok, count} ->
            log_reorder_success(kind, List.first(unique_uuids), count, opts)
            :ok

          {:error, reason} ->
            log_reorder_db_error(kind, unique_uuids, opts)
            {:error, reason}
        end

      {:error, :wrong_scope} = err ->
        log_reorder_rejected(kind, :wrong_scope, length(unique_uuids), opts)
        err
    end
  end

  defp project_scope_check(_is_template?, []), do: :empty

  defp project_scope_check(is_template?, unique_uuids) do
    rows =
      from(p in Project, where: p.uuid in ^unique_uuids, select: p.is_template)
      |> repo().all()

    cond do
      rows == [] -> :empty
      Enum.all?(rows, &(&1 == is_template?)) -> :ok
      true -> {:error, :wrong_scope}
    end
  end

  defp write_project_positions(unique_uuids) do
    repo().transaction(fn ->
      pairs = Enum.with_index(unique_uuids, 1)

      Enum.each(pairs, fn {uuid, idx} ->
        from(p in Project, where: p.uuid == ^uuid)
        |> repo().update_all(set: [position: -idx])
      end)

      pairs
      |> Enum.reduce(0, fn {uuid, idx}, total ->
        {n, _} =
          from(p in Project, where: p.uuid == ^uuid)
          |> repo().update_all(set: [position: idx])

        total + n
      end)
    end)
  end

  @doc "Total number of projects (including templates)."
  @spec count_projects() :: non_neg_integer()
  def count_projects, do: repo().aggregate(Project, :count, :uuid)

  @doc """
  Lists projects that are templates, in `position`-then-date-added
  order. Date-added (not name) is the secondary sort so renaming a
  template doesn't shuffle it in the list. After a manual drag,
  templates with explicit positions land at the top in the user's
  order; un-touched templates fall to the bottom by date-added.
  `uuid` tiebreaks within the same `inserted_at` second.
  """
  @spec list_templates() :: [Project.t()]
  def list_templates do
    Project
    |> where([p], p.is_template == true)
    |> order_by([p], asc: p.position, asc: p.inserted_at, asc: p.uuid)
    |> repo().all()
  end

  @doc "Total number of template projects."
  @spec count_templates() :: non_neg_integer()
  def count_templates do
    Project
    |> where([p], p.is_template == true)
    |> repo().aggregate(:count, :uuid)
  end

  @doc "Running projects (started, not archived, not yet completed)."
  @spec list_active_projects() :: [Project.t()]
  def list_active_projects do
    Project
    |> where(
      [p],
      p.is_template == false and is_nil(p.archived_at) and not is_nil(p.started_at) and
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
      p.is_template == false and is_nil(p.archived_at) and not is_nil(p.completed_at)
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
      p.is_template == false and is_nil(p.archived_at) and is_nil(p.started_at) and
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
      p.is_template == false and is_nil(p.archived_at) and is_nil(p.started_at) and
        p.start_mode == "immediate"
    )
    |> order_by([p], desc: p.inserted_at)
    |> repo().all()
  end

  @doc """
  Counts of assignments by status across active non-template projects.
  Returns a map like %{"todo" => 5, "in_progress" => 2, "done" => 10}.

  Filters on `is_nil(p.archived_at)` to match the dashboard's intent —
  assignments inside archived projects shouldn't inflate the workload
  stats shown alongside `list_active_projects/0`.
  """
  @spec assignment_status_counts() :: %{optional(String.t()) => non_neg_integer()}
  def assignment_status_counts do
    from(a in Assignment,
      join: p in Project,
      on: p.uuid == a.project_uuid,
      where: p.is_template == false and is_nil(p.archived_at),
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
              p.is_template == false and is_nil(p.archived_at),
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
    projects_by_uuid = Map.new(projects, &{&1.uuid, &1})

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

    hours_by_project = batched_planned_hours(projects_by_uuid, uuids)

    Enum.map(projects, fn p ->
      c = Map.get(counts_by_project, p.uuid, %{})
      done = Map.get(c, "done", 0)
      in_progress = Map.get(c, "in_progress", 0)
      todo = Map.get(c, "todo", 0)
      total = done + in_progress + todo

      total_hours = Map.get(hours_by_project, p.uuid, 0.0)

      # `Project.planned_end_for/2` skips weekend days for weekday-only
      # projects so the dashboard's `late` flag aligns with the project
      # page's planned-end date.
      planned_end = Project.planned_end_for(p, total_hours)

      %{
        project: p,
        total: total,
        done: done,
        in_progress: in_progress,
        progress_pct: if(total > 0, do: round(done / total * 100), else: 0),
        total_hours: total_hours,
        planned_end: planned_end
      }
    end)
  end

  # Batched sum of estimated hours per project. Joins each assignment
  # to its task for the duration fallback (assignment.estimated_duration
  # takes precedence; otherwise task.estimated_duration). Returns
  # %{project_uuid => float_hours}; projects without durations are absent.
  defp batched_planned_hours(_projects_by_uuid, []), do: %{}

  defp batched_planned_hours(projects_by_uuid, uuids) do
    from(a in Assignment,
      join: t in assoc(a, :task),
      where: a.project_uuid in ^uuids,
      select: {
        a.project_uuid,
        a.estimated_duration,
        a.estimated_duration_unit,
        a.counts_weekends,
        t.estimated_duration,
        t.estimated_duration_unit
      }
    )
    |> repo().all()
    |> Enum.reduce(%{}, fn {puuid, a_dur, a_unit, a_cw, t_dur, t_unit}, acc ->
      project = Map.get(projects_by_uuid, puuid)
      cw? = if is_nil(a_cw), do: project && project.counts_weekends, else: a_cw

      {dur, unit} =
        if a_dur && a_unit, do: {a_dur, a_unit}, else: {t_dur, t_unit}

      hours = Task.to_hours(dur, unit, cw?)
      Map.update(acc, puuid, hours, &(&1 + hours))
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

    # `:serializable` on the outer transaction so the cycle-check guard
    # inside `add_dependency/2` (called via `clone_one_dependency_in_tx/1`)
    # actually runs at serializable isolation. Postgres only honors the
    # isolation level set on the outermost transaction; the nested
    # `repo().transaction(..., isolation: :serializable)` inside
    # `add_dependency/2` would otherwise become a savepoint at the
    # outer transaction's level (`read_committed` by default), silently
    # dropping the cycle-race protection the docstring advertises.
    # Template clones are short and rare; the isolation cost is negligible.
    repo().transaction(
      fn ->
        project = create_project_in_tx(attrs)
        uuid_map = clone_assignments_in_tx(template_assignments, project)
        clone_dependencies_in_tx(template_deps, uuid_map)
        project
      end,
      isolation: :serializable
    )
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

  @doc """
  Stamps `started_at` on the project and broadcasts `:project_started`.

  `started_at` defaults to `DateTime.utc_now()`. Pass a `%DateTime{}` to
  backdate (the user picked an earlier date in the start-project modal)
  or future-date (the project is being prepared but the actual start
  is later than today).
  """
  @spec start_project(Project.t(), DateTime.t() | nil) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def start_project(%Project{} = p, started_at \\ nil) do
    started_at = started_at || DateTime.utc_now()

    with {:ok, updated} <-
           p |> Project.changeset(%{started_at: started_at}) |> repo().update() do
      ProjectsPubSub.broadcast_project(:project_started, project_payload(updated))
      {:ok, updated}
    end
  end

  @doc "Soft-hides the project by stamping `archived_at`. Idempotent — re-archiving rewrites the timestamp."
  @spec archive_project(Project.t()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def archive_project(%Project{} = p) do
    with {:ok, updated} <-
           p |> Project.changeset(%{archived_at: DateTime.utc_now()}) |> repo().update() do
      ProjectsPubSub.broadcast_project(:project_archived, project_payload(updated))
      {:ok, updated}
    end
  end

  @doc "Restores an archived project by clearing `archived_at`."
  @spec unarchive_project(Project.t()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def unarchive_project(%Project{} = p) do
    with {:ok, updated} <-
           p |> Project.changeset(%{archived_at: nil}) |> repo().update() do
      ProjectsPubSub.broadcast_project(:project_unarchived, project_payload(updated))
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
    # Auto-assign the next position so a fresh add lands at the
    # bottom of the project's manually-reordered timeline. Caller-
    # supplied positions win — covers `clone_template/2` (which
    # preserves the source assignment's position) and any future
    # programmatic batch insert that wants explicit ordering.
    project_uuid = Map.get(attrs, "project_uuid") || Map.get(attrs, :project_uuid)

    attrs =
      put_default_position(attrs, fn -> next_assignment_position(project_uuid) end)

    with {:ok, a} <- %Assignment{} |> Assignment.changeset(attrs) |> repo().insert() do
      ProjectsPubSub.broadcast_assignment(:assignment_created, %{
        uuid: a.uuid,
        project_uuid: a.project_uuid
      })

      {:ok, a}
    end
  end

  @doc """
  Next available `position` for a new assignment within the given
  project — one past the current per-project max, falling back to
  `1` on an empty project.
  """
  @spec next_assignment_position(uuid() | nil) :: integer()
  def next_assignment_position(nil), do: 1

  def next_assignment_position(project_uuid) do
    case repo().one(
           from(a in Assignment, where: a.project_uuid == ^project_uuid, select: max(a.position))
         ) do
      nil -> 1
      n -> n + 1
    end
  end

  @doc """
  Creates the root assignment AND any closure-pulled assignments in one
  serializable transaction, then wires `Dependency` rows according to
  the `TaskDependency` graph between the resulting assignments.

  Drives the assignment-form's "this task pulls in N more" UX: the user
  picks a task, the closure tree shows what'll be dragged in, the user
  optionally prunes nodes via `excluded_task_uuids`, and on save this
  function lands the kept set atomically.

  ## Parameters

    * `root_task_uuid` — the task the user explicitly picked.
    * `project_uuid` — target project.
    * `attrs` — the form's `assignment` params, used for the root
      assignment's description/duration/assignee/etc. overrides.
    * `opts`:
        - `:excluded_task_uuids` — `MapSet` of task uuids the user
          unticked in the closure tree. Excluded tasks are skipped, but
          their template-dep edges that touch *kept* tasks are still
          wired (so removing a leaf doesn't break upstream wiring).
          Defaults to `MapSet.new()`.

  Returns `{:ok, %{root: assignment, extras: [assignment, ...]}}` on
  success or `{:error, reason}` on failure. The transaction rolls back
  cleanly on any failure — partial closure inserts won't leak.

  Tasks already represented by an assignment in the project are
  *reused* (not duplicated) when wiring deps; a closure node whose
  task already has an assignment becomes a wiring target without
  triggering an insert.
  """
  @spec create_assignments_with_closure(uuid(), uuid(), map(), keyword()) ::
          {:ok, %{root: Assignment.t(), extras: [Assignment.t()]}}
          | {:error, term()}
  def create_assignments_with_closure(root_task_uuid, project_uuid, attrs, opts \\ []) do
    excluded = Keyword.get(opts, :excluded_task_uuids, MapSet.new())
    tree = task_closure(root_task_uuid, project_uuid)

    if is_nil(tree) do
      {:error, :task_not_found}
    else
      # `:serializable` so the closure cycle-check + the chained
      # `add_dependency/2` calls (which themselves want serializable)
      # share one outer transaction. Postgres only honors the isolation
      # set on the outermost; nested `repo().transaction(_, isolation:
      # :serializable)` calls become savepoints at the outer's level.
      repo().transaction(
        fn ->
          do_create_assignments_with_closure(tree, project_uuid, attrs, excluded)
        end,
        isolation: :serializable
      )
    end
  end

  defp do_create_assignments_with_closure(tree, project_uuid, attrs, excluded) do
    closure_tasks = flatten_closure(tree)
    root_uuid = tree.task.uuid

    # Map task_uuid → assignment_uuid for ALL tasks in the closure that
    # already have an assignment in the project. Built up as we
    # insert; seeded with what already exists so wiring spans new +
    # pre-existing rows uniformly.
    existing_map = existing_task_assignment_map(project_uuid, Map.keys(closure_tasks))

    # Insertion order = post-order DFS of the kept subtree: deepest
    # leaves first, the user's pick (root) last. Each `create_*` call
    # auto-assigns `next_assignment_position(project_uuid)`, so the
    # row order on disk matches execution order — prerequisites land
    # at lower positions, the picked task at the highest.
    insertion_order = topological_insertion_order(tree, excluded)

    {root, extras_rev, final_map} =
      Enum.reduce(insertion_order, {nil, [], existing_map}, fn task_uuid,
                                                               {root_acc, extras_acc, map} ->
        cond do
          # Reuse: another assignment for this task already exists in
          # the project AND it isn't the user's explicit pick. Wiring
          # will reference the existing uuid; no insert.
          Map.has_key?(map, task_uuid) and task_uuid != root_uuid ->
            {root_acc, extras_acc, map}

          # Root: insert with the form's attrs (description, duration,
          # assignee, etc.). Always inserts even if a prior assignment
          # exists — the user's explicit pick is an "I want a new
          # assignment for this" action.
          task_uuid == root_uuid ->
            full_attrs =
              attrs
              |> Map.put("task_uuid", task_uuid)
              |> Map.put("project_uuid", project_uuid)

            case create_assignment(full_attrs) do
              {:ok, a} -> {a, extras_acc, Map.put(map, task_uuid, a.uuid)}
              {:error, reason} -> repo().rollback(reason)
            end

          # Closure-pulled task: insert with template defaults.
          true ->
            case create_assignment_from_template(task_uuid, %{
                   "project_uuid" => project_uuid,
                   "status" => "todo"
                 }) do
              {:ok, a} -> {root_acc, [a | extras_acc], Map.put(map, task_uuid, a.uuid)}
              {:error, reason} -> repo().rollback(reason)
            end
        end
      end)

    wire_closure_dependencies(tree, final_map, excluded)

    %{root: root, extras: Enum.reverse(extras_rev)}
  end

  # Post-order DFS of the closure tree, returning a list of task
  # uuids in execution order: deepest leaves first, root last. Skips
  # excluded subtrees entirely (cascading model — an excluded
  # ancestor implies its descendants are also out, matching the
  # form's render-time cascade). Cycle nodes terminate without
  # contributing.
  #
  # `seen` only tracks tasks that contributed an insert (or skipped
  # because the user explicitly excluded them on every path). Skips
  # that come purely from an ancestor-exclusion are NOT recorded in
  # `seen`, so a diamond where the same descendant is reachable via
  # both an excluded and a non-excluded parent still emits the
  # descendant once when traversal reaches it via the non-excluded
  # branch.
  defp topological_insertion_order(tree, excluded) do
    {acc_rev, _seen} = do_topo(tree, excluded, false, MapSet.new(), [])
    Enum.reverse(acc_rev)
  end

  defp do_topo(%{cycle?: true}, _excluded, _ancestor_excluded?, seen, acc), do: {acc, seen}

  defp do_topo(%{task: task, children: children}, excluded, ancestor_excluded?, seen, acc) do
    cond do
      MapSet.member?(seen, task.uuid) ->
        {acc, seen}

      ancestor_excluded? ->
        # Pure ancestor-exclusion skip — don't poison `seen`, so a
        # sibling branch reaching this same task can still emit it.
        # Recurse with `ancestor_excluded?: true` so the cascade still
        # blocks inserts down this branch.
        Enum.reduce(children, {acc, seen}, fn child, {a, s} ->
          do_topo(child, excluded, true, s, a)
        end)

      MapSet.member?(excluded, task.uuid) ->
        # User explicitly excluded this task. Mark it `seen` so other
        # branches reaching the same task won't re-emit it, and
        # cascade the exclusion to descendants.
        seen = MapSet.put(seen, task.uuid)

        Enum.reduce(children, {acc, seen}, fn child, {a, s} ->
          do_topo(child, excluded, true, s, a)
        end)

      true ->
        seen = MapSet.put(seen, task.uuid)

        {acc, seen} =
          Enum.reduce(children, {acc, seen}, fn child, {a, s} ->
            do_topo(child, excluded, false, s, a)
          end)

        # Build the list in reverse; `topological_insertion_order/2`
        # reverses once at the end. Prepending stays O(1) per node;
        # an `acc ++ [_]` here would be O(n²) over the closure depth.
        {[task.uuid | acc], seen}
    end
  end

  defp existing_task_assignment_map(project_uuid, task_uuids) do
    from(a in Assignment,
      where: a.project_uuid == ^project_uuid and a.task_uuid in ^task_uuids,
      select: {a.task_uuid, a.uuid}
    )
    |> repo().all()
    |> Map.new()
  end

  # Walks the closure tree top-down adding `Dependency` rows for every
  # template edge whose endpoints both have an assignment in the
  # project (after excludes). Skipped pairs (one or both excluded /
  # missing) are silently dropped — the dep can't exist if either
  # side doesn't.
  defp wire_closure_dependencies(
         %{task: parent, children: children, cycle?: cycle?},
         map,
         excluded
       ) do
    if cycle? do
      :ok
    else
      Enum.each(children, fn child ->
        wire_child_dependency(parent, child, map, excluded)
        wire_closure_dependencies(child, map, excluded)
      end)
    end
  end

  defp wire_child_dependency(parent, child, map, excluded) do
    child_task_uuid = child.task.uuid

    # Skip the parent→child edge entirely when the child is a
    # cycle terminator. The child *is* an already-visited ancestor;
    # adding this edge would close the cycle in the project's
    # dependency graph and trigger `add_dependency/2`'s cycle guard,
    # rolling back the whole closure insert. The cycle node itself
    # didn't contribute an insert (per `do_topo/5`), so there's no
    # row to wire to anyway.
    if child.cycle? or
         MapSet.member?(excluded, parent.uuid) or
         MapSet.member?(excluded, child_task_uuid) do
      :ok
    else
      parent_assignment = Map.get(map, parent.uuid)
      child_assignment = Map.get(map, child_task_uuid)

      wire_assignment_dependency(parent_assignment, child_assignment)
    end
  end

  defp wire_assignment_dependency(nil, _), do: :ok
  defp wire_assignment_dependency(_, nil), do: :ok

  defp wire_assignment_dependency(parent_assignment, child_assignment) do
    case add_dependency(parent_assignment, child_assignment) do
      {:ok, _} ->
        :ok

      # Duplicate pair = idempotent; cycle = halt.
      {:error, %Ecto.Changeset{} = cs} ->
        if duplicate_constraint?(cs), do: :ok, else: repo().rollback(cs)
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

  @doc """
  Re-indexes the supplied assignment uuids into positions `1..N`
  within the given project. Used by the project-show timeline DnD
  handler.

  All uuids must belong to `project_uuid` — UUIDs that exist in
  another project (or don't exist) abort the whole batch with
  `{:error, :not_in_project}`. Duplicates in the input are deduped
  last-write-wins.

  Two-pass write inside a transaction (negatives → positives) so
  any future unique index on `(project_uuid, position)` would be
  honoured. Returns `:ok` / `{:error, :too_many_uuids}` /
  `{:error, :not_in_project}` / `{:error, term()}`. Audit rows are
  written for every outcome.

  The `@reorder_max_uuids` cap is checked against the **raw input
  list length**, before dedup — a payload over the cap signals a
  misbehaving client (real users can't drag 1000+ rows in one
  batched event), so the rejection is a guard, not a real-user
  constraint. Same shape as `reorder_tasks/2`.
  """
  @spec reorder_assignments(uuid(), [uuid()], keyword()) ::
          :ok | {:error, :too_many_uuids | :not_in_project | term()}
  def reorder_assignments(project_uuid, ordered_uuids, opts \\ [])

  def reorder_assignments(_project_uuid, ordered_uuids, opts)
      when is_list(ordered_uuids) and length(ordered_uuids) > @reorder_max_uuids do
    log_reorder_rejected("assignment", :too_many_uuids, length(ordered_uuids), opts)
    {:error, :too_many_uuids}
  end

  def reorder_assignments(project_uuid, ordered_uuids, opts)
      when is_binary(project_uuid) and is_list(ordered_uuids) do
    unique_uuids = dedupe_uuids(ordered_uuids)

    case assignment_scope_check(project_uuid, unique_uuids) do
      :empty ->
        :ok

      :ok ->
        case write_assignment_positions(unique_uuids) do
          {:ok, count} ->
            log_reorder_success(
              "assignment",
              List.first(unique_uuids),
              count,
              Keyword.put(opts, :metadata, %{"project_uuid" => project_uuid})
            )

            :ok

          {:error, reason} ->
            log_reorder_db_error("assignment", unique_uuids, opts)
            {:error, reason}
        end

      {:error, :not_in_project} = err ->
        log_reorder_rejected("assignment", :not_in_project, length(unique_uuids), opts)
        err
    end
  end

  defp assignment_scope_check(_project_uuid, []), do: :empty

  defp assignment_scope_check(project_uuid, unique_uuids) do
    rows =
      from(a in Assignment, where: a.uuid in ^unique_uuids, select: a.project_uuid)
      |> repo().all()

    cond do
      rows == [] -> :empty
      Enum.all?(rows, &(&1 == project_uuid)) -> :ok
      true -> {:error, :not_in_project}
    end
  end

  defp write_assignment_positions(unique_uuids) do
    repo().transaction(fn ->
      pairs = Enum.with_index(unique_uuids, 1)

      Enum.each(pairs, fn {uuid, idx} ->
        from(a in Assignment, where: a.uuid == ^uuid)
        |> repo().update_all(set: [position: -idx])
      end)

      pairs
      |> Enum.reduce(0, fn {uuid, idx}, total ->
        {n, _} =
          from(a in Assignment, where: a.uuid == ^uuid)
          |> repo().update_all(set: [position: idx])

        total + n
      end)
    end)
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

  When called from inside another transaction (e.g. via
  `create_project_from_template/2` → `clone_template/2`), the inner
  `repo().transaction/2` becomes a savepoint and Postgres ignores
  the inner `isolation:` keyword — the protection only holds if the
  outer transaction is itself opened at `:serializable` (which
  `clone_template/2` does).
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
