defmodule PhoenixKitProjects.Projects do
  @moduledoc "Context for projects, tasks, assignments, and dependencies."

  use Gettext, backend: PhoenixKitProjects.Gettext

  import Ecto.Query

  require Logger

  alias PhoenixKit.Utils.Reorder
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
  @spec list_tasks(keyword()) :: [Task.t()]
  def list_tasks(opts \\ []) do
    sort_by = Keyword.get(opts, :sort_by, :position)
    sort_dir = Keyword.get(opts, :sort_dir, :asc)
    limit_n = Keyword.get(opts, :limit)

    Task
    |> task_order_by(sort_by, sort_dir)
    |> maybe_limit(limit_n)
    |> preload(^@task_preloads)
    |> repo().all()
  end

  # Defensive: only positive integers actually narrow the query.
  # `nil` / zero / negative / non-integer values fall through to the
  # unbounded query so a stray opt (`limit: ""` from URL params, or
  # a math accident upstream) doesn't return an empty list when the
  # user expected everything.
  @spec maybe_limit(Ecto.Queryable.t(), term()) :: Ecto.Queryable.t()
  defp maybe_limit(query, n) when is_integer(n) and n > 0, do: limit(query, ^n)
  defp maybe_limit(query, _), do: query

  defp task_order_by(query, :position, _dir),
    do: order_by(query, [t], asc: t.position, asc: t.inserted_at, asc: t.uuid)

  defp task_order_by(query, :title, :desc),
    do: order_by(query, [t], desc: t.title, asc: t.inserted_at, asc: t.uuid)

  defp task_order_by(query, :title, _asc),
    do: order_by(query, [t], asc: t.title, asc: t.inserted_at, asc: t.uuid)

  defp task_order_by(query, :inserted_at, :desc),
    do: order_by(query, [t], desc: t.inserted_at, asc: t.uuid)

  defp task_order_by(query, :inserted_at, _asc),
    do: order_by(query, [t], asc: t.inserted_at, asc: t.uuid)

  defp task_order_by(query, :estimated_duration, :desc),
    do: order_by(query, [t], desc: t.estimated_duration, asc: t.title, asc: t.uuid)

  defp task_order_by(query, :estimated_duration, _asc),
    do: order_by(query, [t], asc: t.estimated_duration, asc: t.title, asc: t.uuid)

  defp task_order_by(query, _field, _dir),
    do: order_by(query, [t], asc: t.position, asc: t.inserted_at, asc: t.uuid)

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

  @doc """
  Updates a task and broadcasts `:task_updated`.

  Pass `broadcast: false` to skip the broadcast — used by callers that write
  inside their own transaction (e.g. the AI-translation adapter) and don't
  want a `:task_updated` to fire before commit / masquerade as a user edit.
  """
  @spec update_task(Task.t(), map(), keyword()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def update_task(%Task{} = t, attrs, opts \\ []) do
    with {:ok, updated} <- t |> Task.changeset(attrs) |> repo().update() do
      if Keyword.get(opts, :broadcast, true) do
        ProjectsPubSub.broadcast_task(:task_updated, %{uuid: updated.uuid, title: updated.title})
      end

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
  def list_tasks_with_deps(opts \\ []) do
    tasks = list_tasks(opts)
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
        repo().transaction(fn -> collect_template_deps(assignment, targets) end)
        |> case do
          {:ok, deps} ->
            # Per-edge `:dependency_added` broadcasts were suppressed inside the
            # transaction; emit them now the batch has committed so a rollback
            # can't leak an edge that never persisted.
            Enum.each(deps, &broadcast_dep(&1, :dependency_added))
            {:ok, deps}

          {:error, _reason} = err ->
            err
        end
    end
  end

  # Inserts each template-derived dependency (broadcast-suppressed) inside the
  # caller's transaction, accumulating the created `Dependency` rows for the
  # post-commit broadcast. A `nil` from `add_template_dep_in_tx/2` is an
  # already-existing edge (idempotent skip).
  defp collect_template_deps(assignment, targets) do
    Enum.reduce(targets, [], fn target, acc ->
      case add_template_dep_in_tx(assignment, target) do
        nil -> acc
        dep -> [dep | acc]
      end
    end)
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
    # `broadcast: false` — emitted post-commit by `apply_template_dependencies/1`.
    # Returns the dep (to broadcast later) or nil for an already-existing edge.
    case add_dependency(assignment.uuid, dep_assignment_uuid, broadcast: false) do
      {:ok, dep} ->
        dep

      # Duplicate pair is fine — the unique constraint already enforces it.
      {:error, %Ecto.Changeset{} = cs} ->
        if duplicate_constraint?(cs), do: nil, else: repo().rollback(cs)
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
    sort_by = Keyword.get(opts, :sort_by, :position)
    sort_dir = Keyword.get(opts, :sort_dir, :asc)
    limit_n = Keyword.get(opts, :limit)
    status_slug = Keyword.get(opts, :current_status_slug, :all)

    Project
    |> maybe_exclude_templates(include_templates)
    |> exclude_subprojects()
    |> maybe_filter_archived(archived)
    |> maybe_filter_status(status_slug)
    |> project_order_by(sort_by, sort_dir)
    |> maybe_limit(limit_n)
    |> repo().all()
  end

  # Sort by `position` is the canonical "manual" mode and gets a
  # multi-key tiebreak so the order is stable even when many rows
  # share `position: 0` (newly inserted projects that haven't been
  # touched by a drag). Other sorts get the same `inserted_at`/`uuid`
  # tiebreaks for the same reason.
  defp project_order_by(query, :position, _dir) do
    order_by(query, [p], asc: p.position, asc: p.inserted_at, asc: p.uuid)
  end

  defp project_order_by(query, :name, :desc),
    do: order_by(query, [p], desc: p.name, asc: p.inserted_at, asc: p.uuid)

  defp project_order_by(query, :name, _asc),
    do: order_by(query, [p], asc: p.name, asc: p.inserted_at, asc: p.uuid)

  defp project_order_by(query, :inserted_at, :desc),
    do: order_by(query, [p], desc: p.inserted_at, asc: p.uuid)

  defp project_order_by(query, :inserted_at, _asc),
    do: order_by(query, [p], asc: p.inserted_at, asc: p.uuid)

  defp project_order_by(query, :updated_at, :desc),
    do: order_by(query, [p], desc: p.updated_at, asc: p.uuid)

  defp project_order_by(query, :updated_at, _asc),
    do: order_by(query, [p], asc: p.updated_at, asc: p.uuid)

  # Unknown sort field — fall back to position so an unrecognised
  # query param doesn't blow up.
  defp project_order_by(query, _field, _dir),
    do: order_by(query, [p], asc: p.position, asc: p.inserted_at, asc: p.uuid)

  defp maybe_exclude_templates(q, true), do: q
  defp maybe_exclude_templates(q, _), do: where(q, [p], p.is_template == false)

  # A project that is embedded as a sub-project of another project (V127 —
  # its uuid is some assignment's `child_project_uuid`) is reached by drilling
  # into its parent's timeline, never as a standalone row. So every top-level
  # listing/bucket/count excludes it. `not in subquery` is self-correcting: if
  # the linking assignment ever disappears, the project re-surfaces at the top
  # level on its own rather than orphaning.
  defp exclude_subprojects(q) do
    children =
      from(a in Assignment, where: not is_nil(a.child_project_uuid), select: a.child_project_uuid)

    where(q, [p], p.uuid not in subquery(children))
  end

  defp maybe_filter_archived(q, :all), do: q
  defp maybe_filter_archived(q, true), do: where(q, [p], not is_nil(p.archived_at))
  defp maybe_filter_archived(q, _false_or_nil), do: where(q, [p], is_nil(p.archived_at))

  # Workflow-status filter (V125). `:all` = no filter, `nil` = "no status
  # set", a slug = exact match. The slug is the stable cross-boundary
  # identity, so the filter matches both pre-start (catalog-backed) and
  # post-start (cemented) projects whose selected status shares the slug.
  defp maybe_filter_status(q, :all), do: q
  defp maybe_filter_status(q, nil), do: where(q, [p], is_nil(p.current_status_slug))

  defp maybe_filter_status(q, slug) when is_binary(slug),
    do: where(q, [p], p.current_status_slug == ^slug)

  @doc "Fetches a project by uuid, or `nil` if not found."
  @spec get_project(uuid()) :: Project.t() | nil
  def get_project(uuid), do: repo().get(Project, uuid)
  @doc "Fetches a project by uuid. Raises if not found."
  @spec get_project!(uuid()) :: Project.t()
  def get_project!(uuid), do: repo().get!(Project, uuid)

  @doc """
  Fetches multiple projects by uuid in a single query, returning a
  `%{uuid => Project.t()}` map. Missing uuids are silently dropped from
  the result rather than raising — callers can detect them by checking
  `Map.has_key?/2` or comparing the result's keys to the input list.

  Avoids the per-row N+1 host apps would otherwise write to render a
  list of records with linked projects (e.g. an orders index page
  showing each row's project name). Nil + duplicate uuids in the input
  are tolerated.

  Returns an empty map for an empty list.

  ## Examples

      iex> %{name: name} = Projects.get_projects([uuid_a, uuid_b])[uuid_a]
      iex> name
      "Alpha"

      iex> Projects.get_projects([])
      %{}

  """
  @spec get_projects([uuid() | nil]) :: %{uuid() => Project.t()}
  def get_projects([]), do: %{}

  def get_projects(uuids) when is_list(uuids) do
    uuids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] ->
        %{}

      cleaned ->
        Project
        |> where([p], p.uuid in ^cleaned)
        |> repo().all()
        |> Map.new(&{&1.uuid, &1})
    end
  end

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

  @doc """
  Inserts a project and broadcasts `:project_created`.

  Pass `broadcast: false` to skip the broadcast — used by callers that create
  the project inside a larger transaction (template clone) and emit a single
  event once the transaction commits, so a rollback can't leak a
  `:project_created` for a project that never persisted.
  """
  @spec create_project(map(), keyword()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(attrs, opts \\ []) do
    # Auto-assign the next position scoped to the project's
    # `is_template` bucket so a new row lands at the bottom of either
    # the project list or the template list (whichever the row
    # belongs to). Caller-supplied positions still win; covers the
    # template-clone path and any future bulk insert.
    is_template? = template_attr?(attrs)
    attrs = put_default_position(attrs, fn -> next_project_position(is_template?) end)

    with {:ok, project} <- %Project{} |> Project.changeset(attrs) |> repo().insert() do
      if Keyword.get(opts, :broadcast, true) do
        ProjectsPubSub.broadcast_project(:project_created, project_payload(project))
      end

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

  @doc """
  Updates a project and broadcasts `:project_updated`.

  Pass `broadcast: false` to skip the broadcast — used by callers that run
  the update inside a larger transaction (e.g.
  `PhoenixKitProjects.Statuses.update_project_with_statuses/2`) and must
  defer the broadcast until after commit, so a later rollback can't leak a
  phantom `:project_updated` to subscribers. Such callers fire the event
  themselves via `broadcast_project_updated/1` once the transaction commits.
  """
  @spec update_project(Project.t(), map(), keyword()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def update_project(%Project{} = p, attrs, opts \\ []) do
    with {:ok, updated} <- p |> Project.changeset(attrs) |> repo().update() do
      if Keyword.get(opts, :broadcast, true), do: broadcast_project_updated(updated)
      {:ok, updated}
    end
  end

  @doc "Broadcasts a `:project_updated` event for a project (post-commit use)."
  @spec broadcast_project_updated(Project.t()) :: :ok
  def broadcast_project_updated(%Project{} = p) do
    ProjectsPubSub.broadcast_project(:project_updated, project_payload(p))
    :ok
  end

  @doc """
  Sets the project's current workflow-status slug and broadcasts
  `:project_status_changed`. Uses the dedicated, server-owned
  `Project.current_status_changeset/2` (never the form changeset) — go
  through `PhoenixKitProjects.Statuses.set_current_status/3` rather than
  calling this directly, so the slug is validated against the project's
  status list first. `nil` clears the selection.
  """
  @spec set_current_status_slug(Project.t(), String.t() | nil) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def set_current_status_slug(%Project{} = p, slug) do
    with {:ok, updated} <-
           p |> Project.current_status_changeset(%{current_status_slug: slug}) |> repo().update() do
      ProjectsPubSub.broadcast_project(:project_status_changed, project_payload(updated))
      {:ok, updated}
    end
  end

  @doc """
  Deletes a project and broadcasts `:project_deleted`.

  Recursive over **sub-projects** (V127): any project embedded in `p`'s
  timeline (and, transitively, in theirs) is torn down too. Deleting `p`
  DB-cascades its own assignment rows (`project_uuid` is `ON DELETE CASCADE`),
  including the sub-project linking rows — but the child projects those rows
  pointed at would be left orphaned, so they're deleted explicitly here. The
  whole subtree comes down in one transaction; `:project_deleted` is broadcast
  for every project removed.

  Refuses to delete a project that is itself **embedded as a sub-project** of
  another project — its `child_project_uuid` FK is `ON DELETE RESTRICT`, so a
  raw `repo().delete` would raise `Ecto.ConstraintError` rather than return a
  tuple. Such a project is reached (and removed) through its parent's timeline,
  or `detach_subproject/1` first; deleting it standalone returns
  `{:error, :still_a_subproject}`.
  """
  @spec delete_project(Project.t()) :: {:ok, Project.t()} | {:error, :still_a_subproject | term()}
  def delete_project(%Project{} = p) do
    if subproject_link_exists?(p.uuid) do
      {:error, :still_a_subproject}
    else
      repo().transaction(fn -> delete_project_tree_in_tx(p) end)
      |> case do
        {:ok, [top | _] = deleted_projects} ->
          # Broadcast AFTER the transaction commits — a rollback must not leak
          # a `:project_deleted` for a project that still exists.
          Enum.each(deleted_projects, fn d ->
            ProjectsPubSub.broadcast_project(:project_deleted, project_payload(d))
          end)

          {:ok, top}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # True when `child_uuid` is embedded as a sub-project of some parent (i.e. a
  # linking assignment points at it). Guards `delete_project/1` against the
  # `ON DELETE RESTRICT` FK that would otherwise raise mid-transaction.
  defp subproject_link_exists?(child_uuid) do
    repo().exists?(from(a in Assignment, where: a.child_project_uuid == ^child_uuid))
  end

  # Tears `project` and its entire sub-project subtree down inside the caller's
  # transaction. Collects the child-project uuids embedded in this project
  # BEFORE deleting it (the linking rows vanish with the DB cascade), deletes
  # the project, then recurses into each former child. Returns the list of
  # deleted projects (this node first, then descendants); broadcasting is
  # deferred to the non-transactional entry points (`delete_project/1`,
  # `delete_assignment/1`) so a rollback can't leak a `:project_deleted`.
  @spec delete_project_tree_in_tx(Project.t()) :: [Project.t()]
  defp delete_project_tree_in_tx(%Project{} = project) do
    child_uuids =
      repo().all(
        from(a in Assignment,
          where: a.project_uuid == ^project.uuid and not is_nil(a.child_project_uuid),
          select: a.child_project_uuid
        )
      )

    deleted =
      case repo().delete(project) do
        {:ok, d} -> d
        {:error, cs} -> repo().rollback(cs)
      end

    descendants =
      Enum.flat_map(child_uuids, fn cu ->
        case get_project(cu) do
          nil -> []
          child -> delete_project_tree_in_tx(child)
        end
      end)

    [deleted | descendants]
  end

  defp project_payload(p) do
    %{
      uuid: p.uuid,
      name: p.name,
      is_template: p.is_template,
      status_entity_uuid: p.status_entity_uuid,
      current_status_slug: p.current_status_slug,
      external_id: p.external_id
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
          :ok | {:error, :too_many_uuids | :wrong_scope}
  def reorder_projects(ordered_uuids, opts \\ []),
    do: reorder_projects_in_scope(false, "project", ordered_uuids, opts)

  @doc """
  Same as `reorder_projects/2` but scoped to `is_template = true`.
  Audit rows use `template.reordered` so the activity feed
  distinguishes the two.
  """
  @spec reorder_templates([uuid()], keyword()) ::
          :ok | {:error, :too_many_uuids | :wrong_scope}
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
    # Delegates to the shared two-phase index-rewrite primitive. The
    # outer reorder_projects_in_scope/4 already runs the raw-length
    # cap + scope check, so we pass our own cap through so Reorder's
    # default (500) doesn't reject payloads our outer guard accepts.
    Reorder.reorder(Project, unique_uuids, :position,
      repo: repo(),
      max_uuids: @reorder_max_uuids
    )
  end

  @doc """
  Count of projects matching the given filter opts. Defaults match
  `list_projects/1` (excludes templates, excludes archived) so the
  count is paired with the list — sized "Showing X of Y" copy stays
  honest about both numbers.

  Pass `include_templates: true` to count both kinds, or
  `archived: :all` to drop the archived filter.
  """
  @spec count_projects(keyword()) :: non_neg_integer()
  def count_projects(opts \\ []) do
    archived = Keyword.get(opts, :archived, false)
    include_templates = Keyword.get(opts, :include_templates, false)
    status_slug = Keyword.get(opts, :current_status_slug, :all)

    Project
    |> maybe_exclude_templates(include_templates)
    |> exclude_subprojects()
    |> maybe_filter_archived(archived)
    |> maybe_filter_status(status_slug)
    |> repo().aggregate(:count, :uuid)
  end

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
    |> exclude_subprojects()
    |> order_by([p], asc: p.position, asc: p.inserted_at, asc: p.uuid)
    |> repo().all()
  end

  @doc "Total number of template projects."
  @spec count_templates() :: non_neg_integer()
  def count_templates do
    Project
    |> where([p], p.is_template == true)
    |> exclude_subprojects()
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
    |> exclude_subprojects()
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
    |> exclude_subprojects()
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
    |> exclude_subprojects()
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
    |> exclude_subprojects()
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
    # `is_nil(a.child_project_uuid)` drops sub-project linking rows (V127):
    # they're rollup placeholders, not real work — the sub-project's own tasks
    # are counted in their own right. Counting the placeholder too would
    # double-count the sub-project in the workload tile.
    from(a in Assignment,
      join: p in Project,
      on: p.uuid == a.project_uuid,
      where: p.is_template == false and is_nil(p.archived_at) and is_nil(a.child_project_uuid),
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

    # Per-project sum of `progress_pct` across all assignments. The
    # rollup is the average of all assignments' progress percentages
    # — a half-finished task contributes 50%, not 0%. Sum is fetched
    # batched in a single query alongside the status-count query
    # above so summaries stay O(1) per project.
    progress_sum_by_project =
      from(a in Assignment,
        where: a.project_uuid in ^uuids,
        group_by: a.project_uuid,
        select: {a.project_uuid, sum(a.progress_pct)}
      )
      |> repo().all()
      |> Map.new()

    hours_by_project = batched_planned_hours(projects_by_uuid, uuids)

    # Per-project sub-project linking rows (V127), split into "has content" vs
    # "empty" (the child project has no assignments of its own yet). An EMPTY
    # sub-project is **neutral** in the progress average — it shouldn't drag a
    # parent's % down before it has any tasks. We keep the full count for the
    # badge, but subtract the empty ones from the progress denominator.
    {subproject_counts_by_project, empty_subproject_counts_by_project} =
      subproject_count_maps(uuids)

    Enum.map(projects, fn p ->
      c = Map.get(counts_by_project, p.uuid, %{})
      done = Map.get(c, "done", 0)
      in_progress = Map.get(c, "in_progress", 0)
      todo = Map.get(c, "todo", 0)
      total = done + in_progress + todo

      progress_sum = progress_sum_by_project |> Map.get(p.uuid, 0) |> Kernel.||(0)

      total_hours = Map.get(hours_by_project, p.uuid, 0.0)

      # `Project.planned_end_for/2` skips weekend days for weekday-only
      # projects so the dashboard's `late` flag aligns with the project
      # page's planned-end date.
      planned_end = Project.planned_end_for(p, total_hours)

      # Empty sub-project linking rows contribute 0 progress and 1 to `total`;
      # drop them from the denominator so they don't pull the average down.
      empty_subs = Map.get(empty_subproject_counts_by_project, p.uuid, 0)
      progress_total = max(total - empty_subs, 0)

      %{
        project: p,
        total: total,
        done: done,
        in_progress: in_progress,
        progress_pct: if(progress_total > 0, do: round(progress_sum / progress_total), else: 0),
        total_hours: total_hours,
        planned_end: planned_end,
        subproject_count: Map.get(subproject_counts_by_project, p.uuid, 0)
      }
    end)
  end

  # Returns `{counts_by_parent, empty_counts_by_parent}` for sub-project linking
  # rows in `parent_uuids`. "Empty" = the embedded child project has no
  # assignments of its own (no tasks, no nested sub-projects).
  defp subproject_count_maps(parent_uuids) do
    links =
      from(a in Assignment,
        where: a.project_uuid in ^parent_uuids and not is_nil(a.child_project_uuid),
        select: {a.project_uuid, a.child_project_uuid}
      )
      |> repo().all()

    counts = links |> Enum.frequencies_by(&elem(&1, 0))

    child_uuids = links |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    non_empty_children = non_empty_child_lookup(child_uuids)

    empty_counts =
      links
      |> Enum.reject(fn {_parent, child} -> Map.has_key?(non_empty_children, child) end)
      |> Enum.frequencies_by(&elem(&1, 0))

    {counts, empty_counts}
  end

  # `%{child_uuid => true}` for children that have any assignments. A plain map
  # (not a MapSet) keeps membership O(1) and dialyzer-transparent.
  defp non_empty_child_lookup([]), do: %{}

  defp non_empty_child_lookup(child_uuids) do
    from(a in Assignment,
      where: a.project_uuid in ^child_uuids,
      distinct: true,
      select: a.project_uuid
    )
    |> repo().all()
    |> Map.new(&{&1, true})
  end

  @doc """
  Recursive **tree summary** for a project: its own task breakdown plus a nested
  summary for each embedded sub-project, all the way down (V127). Powers the
  hierarchical dashboard card.

  Each node has the shape:

      %{
        project: %Project{},
        task_total: integer,            # direct tasks (assignments with a task)
        task_done / task_in_progress / task_todo: integer,
        subproject_count: integer,      # direct sub-projects
        total: integer,                 # task_total + subproject_count
        progress_pct: integer,          # tasks (done=100) + non-empty children
        total_hours: float,
        planned_end: DateTime.t() | nil,
        children: [node, ...]           # one per sub-project, same shape
      }

  `total` + `progress_pct` + `planned_end` are kept so the existing dashboard
  tier/sort helpers read a node like the flat `project_summaries` map. The
  progress average counts each real task (done = 100, else its slider) and each
  **non-empty** child's rolled progress — empty sub-projects are neutral.

  One `list_assignments/1` per node; depth is bounded by the (acyclic) tree, so
  it's fine for the handful of running projects on the dashboard.
  """
  @spec project_tree_summary(Project.t()) :: map()
  def project_tree_summary(%Project{} = project), do: build_tree_node(project)

  defp build_tree_node(%Project{} = project) do
    assignments = list_assignments(project.uuid)
    {task_rows, link_rows} = Enum.split_with(assignments, &is_nil(&1.child_project_uuid))

    children =
      link_rows
      |> Enum.filter(& &1.child_project)
      |> Enum.map(&build_tree_node(&1.child_project))

    total_hours = node_hours(project, assignments)

    %{
      project: project,
      task_total: length(task_rows),
      task_done: Enum.count(task_rows, &(&1.status == "done")),
      task_in_progress: Enum.count(task_rows, &(&1.status == "in_progress")),
      task_todo: Enum.count(task_rows, &(&1.status == "todo")),
      subproject_count: length(link_rows),
      total: length(task_rows) + length(link_rows),
      progress_pct: node_progress(task_rows, children),
      total_hours: total_hours,
      planned_end: Project.planned_end_for(project, total_hours),
      children: children
    }
  end

  # Count-weighted progress: each real task contributes 100 when done else its
  # slider; each non-empty child contributes its own rolled progress. Empty
  # children are excluded so they don't drag the average down.
  defp node_progress(task_rows, children) do
    task_contribs =
      Enum.map(task_rows, fn a -> if a.status == "done", do: 100, else: a.progress_pct end)

    child_contribs = children |> Enum.reject(&empty_tree_node?/1) |> Enum.map(& &1.progress_pct)
    contribs = task_contribs ++ child_contribs

    case contribs do
      [] -> 0
      _ -> round(Enum.sum(contribs) / length(contribs))
    end
  end

  defp empty_tree_node?(%{task_total: 0, subproject_count: 0}), do: true
  defp empty_tree_node?(_), do: false

  # Sum of estimated hours across a project's assignments. Real tasks fall back
  # to their template's duration; sub-project linking rows carry the child's
  # rolled hours in their denormalized `estimated_duration` (minutes).
  defp node_hours(project, assignments) do
    Enum.reduce(assignments, 0.0, fn a, acc ->
      cw = if is_nil(a.counts_weekends), do: project.counts_weekends, else: a.counts_weekends

      {dur, unit} =
        cond do
          a.estimated_duration && a.estimated_duration_unit ->
            {a.estimated_duration, a.estimated_duration_unit}

          a.task ->
            {a.task.estimated_duration, a.task.estimated_duration_unit}

          true ->
            {nil, nil}
        end

      acc + Task.to_hours(dur, unit, cw)
    end)
  end

  # Batched sum of estimated hours per project. Joins each assignment
  # to its task for the duration fallback (assignment.estimated_duration
  # takes precedence; otherwise task.estimated_duration). Returns
  # %{project_uuid => float_hours}; projects without durations are absent.
  defp batched_planned_hours(_projects_by_uuid, []), do: %{}

  defp batched_planned_hours(projects_by_uuid, uuids) do
    # LEFT join (not inner) so sub-project linking rows — which have no task
    # template (V127) — aren't dropped. Their hours come from the denormalized
    # `estimated_duration` (the child project's rolled-up total, stored in
    # minutes), so the `a_dur && a_unit` branch below uses the assignment value
    # and never dereferences the nil task.
    from(a in Assignment,
      left_join: t in assoc(a, :task),
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
        "counts_weekends" => to_string(template.counts_weekends),
        # Inherit the template's chosen status catalog (nil = shared). The
        # cloned project reads it live until it starts, then cements.
        "status_entity_uuid" => template.status_entity_uuid
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
        project = attrs |> create_project_in_tx() |> inherit_status_slug_in_tx(template)
        uuid_map = clone_assignments_in_tx(template_assignments, project)
        clone_dependencies_in_tx(template_deps, uuid_map)
        project
      end,
      isolation: :serializable
    )
    |> case do
      {:ok, project} ->
        # Every per-row create/dep broadcast inside the clone transaction was
        # suppressed (`broadcast: false`); emit one `:project_created` now that
        # the whole tree has committed, so a rollback leaks nothing and
        # subscribers still learn the new project exists.
        ProjectsPubSub.broadcast_project(:project_created, project_payload(project))
        {:ok, project}

      {:error, _reason} = err ->
        err
    end
  end

  # Carry the template's selected status (a slug) onto the cloned project.
  # Uses the server-owned changeset directly (no broadcast — the project
  # was just created in this transaction and has no subscribers yet).
  defp inherit_status_slug_in_tx(project, %{current_status_slug: slug})
       when is_binary(slug) and slug != "" do
    case project
         |> Project.current_status_changeset(%{current_status_slug: slug})
         |> repo().update() do
      {:ok, updated} -> updated
      {:error, cs} -> repo().rollback(cs)
    end
  end

  defp inherit_status_slug_in_tx(project, _template), do: project

  defp create_project_in_tx(attrs) do
    # `broadcast: false`: the project is created inside the clone transaction;
    # `clone_template/2` emits a single `:project_created` after commit.
    case create_project(attrs, broadcast: false) do
      {:ok, project} -> project
      {:error, cs} -> repo().rollback(cs)
    end
  end

  defp clone_assignments_in_tx(source_assignments, project) do
    Enum.reduce(source_assignments, %{}, fn a, acc ->
      new_uuid =
        if is_nil(a.child_project_uuid) do
          clone_task_assignment_in_tx(a, project)
        else
          clone_subproject_assignment_in_tx(a, project)
        end

      Map.put(acc, a.uuid, new_uuid)
    end)
  end

  defp clone_task_assignment_in_tx(a, project) do
    # `broadcast: false` — cloned inside the clone transaction; the post-commit
    # `:project_created` in `clone_template/2` signals the whole new tree.
    case create_assignment(
           %{
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
           },
           broadcast: false
         ) do
      {:ok, new_a} -> new_a.uuid
      {:error, cs} -> repo().rollback(cs)
    end
  end

  # A sub-project row in the source is **deep-cloned**: its child (a sub-template
  # when cloning a template) is recursively cloned into a fresh project, and a
  # new linking assignment is created pointing at the clone. The single-parent
  # unique index forbids reusing the same child, so the deep copy is mandatory.
  defp clone_subproject_assignment_in_tx(a, project) do
    cloned_child =
      case get_project(a.child_project_uuid) do
        nil ->
          repo().rollback(:missing_child_project)

        child ->
          deep_clone_project_in_tx(child, %{"is_template" => to_string(project.is_template)})
      end

    link_attrs =
      cloned_child.uuid
      |> child_project_rollup()
      |> Map.merge(%{
        project_uuid: project.uuid,
        child_project_uuid: cloned_child.uuid,
        position: a.position
      })

    case %Assignment{} |> Assignment.subproject_changeset(link_attrs) |> repo().insert() do
      {:ok, new_link} -> new_link.uuid
      {:error, cs} -> repo().rollback(cs)
    end
  end

  # Recursively clones `src` (template or project) into a brand-new project:
  # copies its scalar fields, clones every assignment (tasks AND nested
  # sub-projects, via `clone_assignments_in_tx/2`) and re-wires dependencies.
  # `overrides` lets the caller flip `is_template` for the instantiated copy.
  defp deep_clone_project_in_tx(%Project{} = src, overrides) do
    attrs =
      Map.merge(
        %{
          "name" => src.name,
          "description" => src.description,
          # A nested sub-project has no instantiation form to re-supply these,
          # so they must be carried from the source or the clone loses its
          # multilang content, workflow source/settings, and assignee. Mirrors
          # `clone_template/2` (status source) and extends it to the fields only
          # a clone-from-source — not a form — can preserve.
          "translations" => src.translations,
          "settings" => src.settings,
          "status_entity_uuid" => src.status_entity_uuid,
          "assigned_team_uuid" => src.assigned_team_uuid,
          "assigned_department_uuid" => src.assigned_department_uuid,
          "assigned_person_uuid" => src.assigned_person_uuid,
          "counts_weekends" => to_string(src.counts_weekends),
          "start_mode" => src.start_mode,
          "is_template" => "false"
        },
        overrides
      )

    # `inherit_status_slug_in_tx/2` carries the server-owned `current_status_slug`
    # (not a regular changeset field), same as the root template clone.
    new_project = attrs |> create_project_in_tx() |> inherit_status_slug_in_tx(src)
    src_assignments = list_assignments(src.uuid)
    src_deps = list_all_dependencies(src.uuid)
    uuid_map = clone_assignments_in_tx(src_assignments, new_project)
    clone_dependencies_in_tx(src_deps, uuid_map)
    new_project
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
    # `broadcast: false` — inside the clone transaction; the post-commit
    # `:project_created` covers the cloned tree.
    case add_dependency(assignment_uuid, depends_on_uuid, broadcast: false) do
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

    # Stamp `started_at` AND cement the project's workflow statuses in one
    # transaction so a running project never exists with a half-copied
    # status set. `cement_project_statuses/2` is a no-op when entities is
    # unavailable or the project is already cemented (see Statuses).
    txn =
      repo().transaction(fn ->
        case p |> Project.changeset(%{started_at: started_at}) |> repo().update() do
          {:ok, updated} ->
            PhoenixKitProjects.Statuses.cement_project_statuses(updated)
            updated

          {:error, changeset} ->
            repo().rollback(changeset)
        end
      end)

    case txn do
      {:ok, updated} ->
        ProjectsPubSub.broadcast_project(:project_started, project_payload(updated))
        {:ok, updated}

      {:error, _} = err ->
        err
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
    recompute_project_completion(project_uuid, 0)
  end

  # Depth guard: the parent chain (V127 sub-projects) is finite and acyclic by
  # construction (single-parent unique index + inline-only creation), but cap
  # the upward walk defensively so corrupted data can never spin forever.
  @max_rollup_depth 64

  defp recompute_project_completion(project_uuid, depth) do
    # Wrap the read + check + update in a transaction so two concurrent
    # status changes (e.g. task A marked done, task B reopened) can't
    # both observe the same pre-update state and try to mark the project
    # completed twice. The second wins-or-loses but it's idempotent —
    # broadcast and audit-row consumers see exactly one transition.
    result =
      repo().transaction(fn ->
        case get_project(project_uuid) do
          nil -> :ok
          %Project{is_template: true} -> :ok
          project -> decide_completion(project)
        end
      end)
      |> case do
        {:ok, res} -> res
        {:error, _} = err -> err
      end

    # Broadcast the completion transition AFTER the transaction commits, so a
    # rollback can't leak a `:project_completed`/`:project_reopened` for a
    # project that didn't actually settle. `mark_completed`/`mark_reopened`
    # only persist + return the transition; the broadcast lives here.
    case result do
      {:completed, project} ->
        ProjectsPubSub.broadcast_project(:project_completed, project_payload(project))

      {:reopened, project} ->
        ProjectsPubSub.broadcast_project(:project_reopened, project_payload(project))

      _ ->
        :ok
    end

    # After the project's own completion settles, push its rolled-up state onto
    # the parent's linking assignment (if this project is itself a sub-project)
    # and recompute the parent in turn — so completion/progress climbs the tree.
    propagate_rollup_to_parent(project_uuid, depth)

    result
  end

  # If `child_project_uuid` is embedded in some parent assignment, refresh that
  # linking row's denormalized rollup (status / progress / hours / completion)
  # from the child, then recompute the parent so the change keeps climbing.
  # Runs AFTER the child's own transaction commits, so the rollup reads the
  # settled child state.
  defp propagate_rollup_to_parent(_child_project_uuid, depth) when depth >= @max_rollup_depth do
    Logger.warning("[Projects] sub-project rollup depth cap hit (#{@max_rollup_depth}); stopping")
    :ok
  end

  defp propagate_rollup_to_parent(child_project_uuid, depth) do
    case repo().one(from(a in Assignment, where: a.child_project_uuid == ^child_project_uuid)) do
      nil ->
        :ok

      link ->
        case child_project_rollup(child_project_uuid) do
          nil ->
            :ok

          rollup ->
            case link |> Assignment.subproject_changeset(rollup) |> repo().update() do
              {:ok, updated} ->
                ProjectsPubSub.broadcast_assignment(:assignment_updated, %{
                  uuid: updated.uuid,
                  project_uuid: updated.project_uuid
                })

                recompute_project_completion(updated.project_uuid, depth + 1)

              {:error, _cs} ->
                :ok
            end
        end
    end
  end

  # Computes the denormalized rollup a sub-project's linking assignment carries.
  # The child project is the source of truth; this snapshots its current
  # progress/hours/completion into the shape `subproject_changeset/2` casts.
  # Hours are stored in MINUTES (`round(total_hours * 60)`) so sub-hour child
  # totals survive the integer `estimated_duration` column without drift.
  defp child_project_rollup(child_project_uuid) do
    case get_project(child_project_uuid) do
      nil -> nil
      child -> build_child_rollup(child, project_summary(child))
    end
  end

  defp build_child_rollup(child, summary) do
    total_hours = rollup_val(summary, :total_hours, 0.0)
    status = rollup_status(child, summary)

    # A completed sub-project reads as 100% even though the module's
    # `progress_pct` is the average of the per-task sliders (completing a task
    # doesn't move its slider) — otherwise a "done" row would show 0%. For an
    # in-progress sub-project the rolled-up slider average is the right number.
    progress = if status == "done", do: 100, else: rollup_val(summary, :progress_pct, 0)

    %{
      status: status,
      progress_pct: progress,
      estimated_duration: round(total_hours * 60),
      estimated_duration_unit: "minutes",
      track_progress: true,
      completed_at: child.completed_at
    }
  end

  # A sub-project's denormalized status: "done" once the child is completed,
  # "in_progress" once any work exists/has started, else "todo".
  defp rollup_status(%{completed_at: %DateTime{}}, _summary), do: "done"

  defp rollup_status(_child, summary) do
    total = rollup_val(summary, :total, 0)
    done = rollup_val(summary, :done, 0)
    in_progress = rollup_val(summary, :in_progress, 0)
    progress = rollup_val(summary, :progress_pct, 0)

    if total > 0 and (done > 0 or in_progress > 0 or progress > 0),
      do: "in_progress",
      else: "todo"
  end

  defp rollup_val(nil, _key, default), do: default
  defp rollup_val(summary, key, _default) when is_map(summary), do: Map.fetch!(summary, key)

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

  # Persists completion and returns the transition; the `:project_completed`
  # broadcast is emitted by `recompute_project_completion/2` after its
  # transaction commits (never from inside the tx).
  defp mark_completed(project) do
    case project |> Project.changeset(%{completed_at: DateTime.utc_now()}) |> repo().update() do
      {:ok, updated} -> {:completed, updated}
      other -> other
    end
  end

  # Persists reopening and returns the transition; the `:project_reopened`
  # broadcast is emitted by `recompute_project_completion/2` after commit.
  defp mark_reopened(project) do
    case project |> Project.changeset(%{completed_at: nil}) |> repo().update() do
      {:ok, updated} -> {:reopened, updated}
      other -> other
    end
  end

  # ── Assignments ────────────────────────────────────────────────────

  @assignment_preloads [
    :task,
    # Deep-preload the embedded child's assignee (V128) so a sub-project row can
    # show who the sub-project is assigned to.
    {:child_project, [:assigned_team, :assigned_department, assigned_person: [:user]]},
    :assigned_team,
    :assigned_department,
    :completed_by,
    assigned_person: [:user]
  ]

  @assignee_preloads [:assigned_team, :assigned_department, assigned_person: [:user]]

  @doc "Fetches a project with its assignee associations preloaded (V128)."
  @spec get_project_with_assignee(uuid()) :: Project.t() | nil
  def get_project_with_assignee(uuid) do
    Project |> preload(^@assignee_preloads) |> repo().get(uuid)
  end

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

  @doc """
  Fetches the assignments among `uuids` that belong to `project_uuid`, in a
  single query. Used to authorize multi-endpoint operations (e.g. dependency
  removal, which must confirm BOTH endpoints live in the viewed project)
  without one round-trip per uuid. No preloads — callers only check scope.
  """
  @spec scoped_assignments([uuid()], uuid()) :: [Assignment.t()]
  def scoped_assignments(uuids, project_uuid) when is_list(uuids) do
    Assignment
    |> where([a], a.uuid in ^uuids and a.project_uuid == ^project_uuid)
    |> repo().all()
  end

  @doc "Returns a changeset for the given assignment."
  @spec change_assignment(Assignment.t(), map()) :: Ecto.Changeset.t()
  def change_assignment(%Assignment{} = a, attrs \\ %{}), do: Assignment.changeset(a, attrs)

  @doc """
  Inserts an assignment and broadcasts `:assignment_created`.

  Pass `broadcast: false` to skip the broadcast — used by callers inserting
  inside a larger transaction (template clone, closure-pull) that emit their
  own event after the transaction commits.
  """
  @spec create_assignment(map(), keyword()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t()}
  def create_assignment(attrs, opts \\ []) do
    # Auto-assign the next position so a fresh add lands at the
    # bottom of the project's manually-reordered timeline. Caller-
    # supplied positions win — covers `clone_template/2` (which
    # preserves the source assignment's position) and any future
    # programmatic batch insert that wants explicit ordering.
    project_uuid = Map.get(attrs, "project_uuid") || Map.get(attrs, :project_uuid)

    attrs =
      put_default_position(attrs, fn -> next_assignment_position(project_uuid) end)

    with {:ok, a} <- %Assignment{} |> Assignment.changeset(attrs) |> repo().insert() do
      if Keyword.get(opts, :broadcast, true) do
        ProjectsPubSub.broadcast_assignment(:assignment_created, %{
          uuid: a.uuid,
          project_uuid: a.project_uuid
        })
      end

      {:ok, a}
    end
  end

  @doc """
  Adds a **sub-project** to `parent_project_uuid`: creates a fresh child
  project (named via `child_attrs`) and links it into the parent's timeline as
  an assignment whose `child_project_uuid` points at the new child. The child
  starts empty (immediate-start); add its own tasks by opening it. The linking
  assignment behaves like any task — drag, dependencies — and its
  status/progress/hours roll up from the child (see `child_project_rollup/1`).

  The child **inherits the parent's `is_template` flag**: a sub-project added to
  a template is itself a sub-template, and `create_project_from_template/2`
  deep-clones the whole sub-template subtree into real child projects when the
  parent template is instantiated.

  Both inserts run in one transaction. Returns
  `{:ok, %{child_project: Project.t(), assignment: Assignment.t()}}`.

  Inline-only creation makes a cycle structurally impossible (the child is
  brand-new and can't already be an ancestor), so no cycle guard runs here. A
  future "link existing project as a sub-project" path MUST add an ancestor
  check before assigning `child_project_uuid`.
  """
  @spec create_subproject(uuid(), map()) ::
          {:ok, %{child_project: Project.t(), assignment: Assignment.t()}}
          | {:error, :parent_not_found | Ecto.Changeset.t()}
  def create_subproject(parent_project_uuid, child_attrs) do
    case get_project(parent_project_uuid) do
      nil -> {:error, :parent_not_found}
      parent -> do_create_subproject(parent, child_attrs)
    end
  end

  defp do_create_subproject(%Project{} = parent, child_attrs) do
    parent_project_uuid = parent.uuid

    attrs =
      child_attrs
      |> Map.merge(%{"is_template" => to_string(parent.is_template), "start_mode" => "immediate"})

    repo().transaction(fn ->
      child =
        case create_project(attrs) do
          {:ok, c} -> c
          {:error, cs} -> repo().rollback(cs)
        end

      link_attrs =
        child.uuid
        |> child_project_rollup()
        |> Map.merge(%{
          project_uuid: parent_project_uuid,
          child_project_uuid: child.uuid,
          position: next_assignment_position(parent_project_uuid)
        })

      link =
        case %Assignment{} |> Assignment.subproject_changeset(link_attrs) |> repo().insert() do
          {:ok, a} -> a
          {:error, cs} -> repo().rollback(cs)
        end

      %{child_project: child, assignment: link}
    end)
    |> case do
      {:ok, %{assignment: link} = result} ->
        ProjectsPubSub.broadcast_assignment(:assignment_created, %{
          uuid: link.uuid,
          project_uuid: link.project_uuid
        })

        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Links an **existing** standalone project into `parent_project_uuid` as a
  sub-project (V127) — the "nest this project" path, alongside the create-new
  `create_subproject/2`. The child keeps its whole subtree, and drops off the
  top-level list once linked.

  Guards: the child must exist, not be the parent, match the parent's
  `is_template`, not already be a sub-project (the single-parent unique index),
  and not be an **ancestor** of the parent (which would create a cycle). Errors:
  `:not_found`, `:self_link`, `:kind_mismatch`, `:already_subproject`,
  `:would_create_cycle`.
  """
  @spec link_subproject(uuid(), uuid()) ::
          {:ok, %{child_project: Project.t(), assignment: Assignment.t()}}
          | {:error,
             :not_found
             | :self_link
             | :kind_mismatch
             | :already_subproject
             | :would_create_cycle
             | Ecto.Changeset.t()}
  # Arbitrary fixed key for the transaction-scoped advisory lock that serializes
  # sub-project links. Global (links are rare admin actions), so two reciprocal
  # links can't interleave their ancestor checks.
  @subproject_link_lock 8_126_126

  def link_subproject(parent_project_uuid, child_project_uuid) do
    repo().transaction(fn ->
      # Without this lock, concurrent `A → B` and `B → A` links each pass the
      # ancestor check (neither is yet the other's ancestor) and both insert,
      # creating a cycle. The advisory lock serializes link operations so the
      # second sees the first's committed row.
      repo().query!("SELECT pg_advisory_xact_lock($1)", [@subproject_link_lock])

      with {:ok, parent} <- fetch_project(parent_project_uuid),
           {:ok, child} <- fetch_project(child_project_uuid),
           :ok <- validate_link(parent, child),
           {:ok, result} <- do_link_subproject(parent, child) do
        result
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> case do
      {:ok, %{assignment: link} = result} ->
        # Broadcast + roll up AFTER the transaction commits — a rollback (cycle
        # guard, unique-index race) must not leak an `:assignment_created` for a
        # link that never persisted. `recompute_project_completion/1` runs its
        # own transaction over the committed state.
        ProjectsPubSub.broadcast_assignment(:assignment_created, %{
          uuid: link.uuid,
          project_uuid: link.project_uuid
        })

        recompute_project_completion(link.project_uuid)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_project(uuid) do
    case get_project(uuid) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  defp validate_link(%Project{uuid: same}, %Project{uuid: same}), do: {:error, :self_link}

  defp validate_link(%Project{} = parent, %Project{} = child) do
    cond do
      parent.is_template != child.is_template -> {:error, :kind_mismatch}
      child.uuid in project_ancestor_uuids(parent.uuid) -> {:error, :would_create_cycle}
      true -> :ok
    end
  end

  defp do_link_subproject(parent, child) do
    link_attrs =
      child.uuid
      |> child_project_rollup()
      |> Map.merge(%{
        project_uuid: parent.uuid,
        child_project_uuid: child.uuid,
        position: next_assignment_position(parent.uuid)
      })

    case %Assignment{} |> Assignment.subproject_changeset(link_attrs) |> repo().insert() do
      {:ok, link} ->
        # Broadcast + recompute happen in `link_subproject/2` after the
        # transaction commits (see the `|> case` there) — never inside the tx.
        {:ok, %{child_project: child, assignment: link}}

      {:error, %Ecto.Changeset{} = cs} ->
        # The partial-unique index on `child_project_uuid` means "already a
        # sub-project of someone".
        if Enum.any?(cs.errors, fn {field, _} -> field == :child_project_uuid end) do
          {:error, :already_subproject}
        else
          {:error, cs}
        end
    end
  end

  @doc """
  Projects eligible to be linked as a sub-project of `parent` (V127): standalone
  (not already a sub-project), same `is_template`, not archived, not the parent,
  and not one of the parent's ancestors (cycle-safe). Ordered by name for a
  picker.
  """
  @spec available_projects_to_link(Project.t()) :: [Project.t()]
  def available_projects_to_link(%Project{} = parent) do
    excluded = [parent.uuid | project_ancestor_uuids(parent.uuid)]

    Project
    |> where([p], p.is_template == ^parent.is_template and is_nil(p.archived_at))
    |> where([p], p.uuid not in ^excluded)
    |> exclude_subprojects()
    |> order_by([p], asc: p.name, asc: p.uuid)
    |> repo().all()
  end

  @doc """
  Detaches a sub-project from its parent (V127) — the non-destructive inverse of
  the cascade in `delete_assignment/1`. Deletes **only the linking assignment**,
  leaving the child project + its whole subtree intact; it becomes a standalone
  top-level project again. Recomputes the former parent (one fewer rolled-up
  item).
  """
  @spec detach_subproject(Assignment.t()) :: {:ok, Assignment.t()} | {:error, term()}
  def detach_subproject(%Assignment{child_project_uuid: child_uuid} = link)
      when is_binary(child_uuid) do
    with {:ok, deleted} <- repo().delete(link) do
      ProjectsPubSub.broadcast_assignment(:assignment_deleted, %{
        uuid: deleted.uuid,
        project_uuid: deleted.project_uuid
      })

      recompute_project_completion(deleted.project_uuid)

      # The child is standalone again — nudge any project list to refresh.
      case get_project(child_uuid) do
        nil -> :ok
        child -> ProjectsPubSub.broadcast_project(:project_updated, project_payload(child))
      end

      {:ok, deleted}
    end
  end

  # Ancestor project uuids of `project_uuid`, walking up the linking-assignment
  # chain (parent of X = the project whose linking row embeds X). Order
  # unspecified; guards against a corrupt cycle by tracking visited uuids.
  defp project_ancestor_uuids(project_uuid), do: walk_ancestors(project_uuid, [])

  defp walk_ancestors(uuid, acc) do
    case repo().one(
           from(a in Assignment, where: a.child_project_uuid == ^uuid, select: a.project_uuid)
         ) do
      nil ->
        acc

      parent_uuid ->
        if parent_uuid in acc, do: acc, else: walk_ancestors(parent_uuid, [parent_uuid | acc])
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
      |> case do
        {:ok, %{root: root, extras: extras} = result} ->
          # Every per-row create/dep broadcast inside the serializable closure
          # transaction was suppressed (`broadcast: false`); emit the
          # `:assignment_created` events now the batch has committed, so a
          # rollback leaks nothing.
          for a <- [root | extras], not is_nil(a) do
            ProjectsPubSub.broadcast_assignment(:assignment_created, %{
              uuid: a.uuid,
              project_uuid: a.project_uuid
            })
          end

          {:ok, result}

        {:error, _reason} = err ->
          err
      end
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

            # `broadcast: false` — created inside the serializable closure
            # transaction; `create_assignments_with_closure/4` emits the
            # `:assignment_created` events after commit.
            case create_assignment(full_attrs, broadcast: false) do
              {:ok, a} -> {a, extras_acc, Map.put(map, task_uuid, a.uuid)}
              {:error, reason} -> repo().rollback(reason)
            end

          # Closure-pulled task: insert with template defaults.
          true ->
            case create_assignment_from_template(
                   task_uuid,
                   %{"project_uuid" => project_uuid, "status" => "todo"},
                   broadcast: false
                 ) do
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
    # `broadcast: false` — wired inside the closure transaction; the post-commit
    # `:assignment_created` events trigger the subscriber refresh.
    case add_dependency(parent_assignment, child_assignment, broadcast: false) do
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
  @spec create_assignment_from_template(uuid(), map(), keyword()) ::
          {:ok, Assignment.t()} | {:error, :task_not_found | Ecto.Changeset.t()}
  def create_assignment_from_template(task_uuid, attrs, opts \\ []) do
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
        create_assignment(merged, opts)
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
  @spec update_assignment_form(Assignment.t(), map(), keyword()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t()}
  def update_assignment_form(%Assignment{} = a, attrs, opts \\ []) do
    with {:ok, updated} <- a |> Assignment.changeset(attrs) |> repo().update() do
      if Keyword.get(opts, :broadcast, true) do
        ProjectsPubSub.broadcast_assignment(:assignment_updated, %{
          uuid: updated.uuid,
          project_uuid: updated.project_uuid
        })
      end

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

  @doc """
  Deletes an assignment and broadcasts `:assignment_deleted`.

  For a **sub-project** linking row (`child_project_uuid` set, V127) this tears
  the child project subtree down too — "removing the sub-project task removes
  the sub-project", matching the boss's "same as a task" semantics. The linking
  row is deleted first (the `child_project_uuid` FK is `ON DELETE RESTRICT`, so
  the child can't be removed while it's still referenced), then the child tree
  via `delete_project_tree_in_tx/1`. Both in one transaction.
  """
  @spec delete_assignment(Assignment.t()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t() | term()}
  def delete_assignment(%Assignment{child_project_uuid: nil} = a) do
    with {:ok, deleted} <- repo().delete(a) do
      ProjectsPubSub.broadcast_assignment(:assignment_deleted, %{
        uuid: deleted.uuid,
        project_uuid: deleted.project_uuid
      })

      {:ok, deleted}
    end
  end

  def delete_assignment(%Assignment{child_project_uuid: child_uuid} = a) do
    repo().transaction(fn ->
      deleted =
        case repo().delete(a) do
          {:ok, d} -> d
          {:error, cs} -> repo().rollback(cs)
        end

      deleted_projects =
        case get_project(child_uuid) do
          nil -> []
          child -> delete_project_tree_in_tx(child)
        end

      {deleted, deleted_projects}
    end)
    |> case do
      {:ok, {deleted, deleted_projects}} ->
        # Broadcast AFTER commit (mirrors `delete_project/1`): the linking-row
        # delete and the child subtree both have to survive the transaction
        # before any subscriber is told they're gone.
        ProjectsPubSub.broadcast_assignment(:assignment_deleted, %{
          uuid: deleted.uuid,
          project_uuid: deleted.project_uuid
        })

        Enum.each(deleted_projects, fn d ->
          ProjectsPubSub.broadcast_project(:project_deleted, project_payload(d))
        end)

        {:ok, deleted}

      {:error, reason} ->
        {:error, reason}
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
    |> preload(depends_on: [:task, :child_project])
    |> repo().all()
  end

  @doc "All dependencies across every assignment in a project (used when cloning templates)."
  @spec list_all_dependencies(uuid()) :: [Dependency.t()]
  def list_all_dependencies(project_uuid) do
    from(d in Dependency,
      join: a in Assignment,
      on: d.assignment_uuid == a.uuid,
      where: a.project_uuid == ^project_uuid,
      # `:child_project` alongside `:task` so a dependency whose target is a
      # sub-project (no task template, V127) can still render a label.
      preload: [depends_on: [:task, :child_project]]
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
  @spec add_dependency(uuid(), uuid(), keyword()) ::
          {:ok, Dependency.t()} | {:error, Ecto.Changeset.t()}
  def add_dependency(assignment_uuid, depends_on_uuid, opts \\ []) do
    changeset =
      Dependency.changeset(%Dependency{}, %{
        assignment_uuid: assignment_uuid,
        depends_on_uuid: depends_on_uuid
      })

    if changeset.valid? do
      do_add_dependency_in_serializable_tx(assignment_uuid, depends_on_uuid, changeset, opts)
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  defp do_add_dependency_in_serializable_tx(assignment_uuid, depends_on_uuid, changeset, opts) do
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
        # Callers inside a larger transaction (clone, closure-pull, template-dep
        # application) pass `broadcast: false` and emit their own event after the
        # outer transaction commits, so a rollback can't leak a `:dependency_added`.
        if Keyword.get(opts, :broadcast, true), do: broadcast_dep(dep, :dependency_added)
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
      preload: [:task, :child_project],
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

  # ---------------------------------------------------------------
  # Strategy-driven reorder (bulk "Sort by …" modal)
  # ---------------------------------------------------------------
  #
  # DnD writes positions one drop at a time; the Reorder modal lets
  # the user rewrite many positions at once by picking a strategy
  # (name asc/desc, created asc/desc, reverse). Scope is either
  # `:all` (rewrite every row contiguously) or a uuid list ("permute
  # in place" — the selected rows keep the slots they already occupy,
  # only the ordering within those slots changes). Non-selected rows
  # never move under permute-in-place — that's the whole reason for
  # the mode.

  @type reorder_strategy ::
          :name_asc | :name_desc | :created_asc | :created_desc | :reverse

  @valid_project_strategies ~w(name_asc name_desc created_asc created_desc reverse)a
  @valid_task_strategies ~w(name_asc name_desc created_asc created_desc reverse)a

  @doc """
  Bulk-reorder projects by a sort strategy.

    * `scope = :all` — load every non-template project, sort by
      strategy, write contiguous 1..N positions via the existing
      `Reorder.reorder` primitive.
    * `scope = [uuid, ...]` — load only those projects, validate they
      are all non-templates, permute them within the slots they
      already occupy (their existing `position` values). Untouched
      projects are not re-indexed.

  Returns `:ok`, `{:error, :wrong_scope}` if any uuid maps to a
  template or unknown row, `{:error, :too_many_uuids}` past the cap,
  or `{:error, term}` on DB failure. Audit row logged on success.
  """
  @spec reorder_projects_by(reorder_strategy(), :all | [uuid()], keyword()) ::
          :ok | {:error, :wrong_scope | :too_many_uuids | term()}
  def reorder_projects_by(strategy, scope, opts \\ [])

  def reorder_projects_by(strategy, _scope, _opts) when strategy not in @valid_project_strategies,
    do: {:error, :invalid_strategy}

  def reorder_projects_by(strategy, :all, opts),
    do: reorder_all_projects_in_scope(strategy, false, "project", opts)

  def reorder_projects_by(strategy, uuids, opts) when is_list(uuids),
    do: permute_projects_by(strategy, uuids, false, "project", opts)

  @doc """
  Bulk-reorder templates by strategy. Same shape as
  `reorder_projects_by/3` but scoped to `is_template = true`.
  """
  @spec reorder_templates_by(reorder_strategy(), :all | [uuid()], keyword()) ::
          :ok | {:error, :wrong_scope | :too_many_uuids | term()}
  def reorder_templates_by(strategy, scope, opts \\ [])

  def reorder_templates_by(strategy, _scope, _opts)
      when strategy not in @valid_project_strategies,
      do: {:error, :invalid_strategy}

  def reorder_templates_by(strategy, :all, opts),
    do: reorder_all_projects_in_scope(strategy, true, "template", opts)

  def reorder_templates_by(strategy, uuids, opts) when is_list(uuids),
    do: permute_projects_by(strategy, uuids, true, "template", opts)

  @doc """
  Bulk-reorder tasks by strategy. Strategy `:name_asc` / `:name_desc`
  sorts by `title` (tasks don't have a `name` field).
  """
  @spec reorder_tasks_by(reorder_strategy(), :all | [uuid()], keyword()) ::
          :ok | {:error, :too_many_uuids | term()}
  def reorder_tasks_by(strategy, scope, opts \\ [])

  def reorder_tasks_by(strategy, _scope, _opts) when strategy not in @valid_task_strategies,
    do: {:error, :invalid_strategy}

  def reorder_tasks_by(strategy, :all, opts),
    do: reorder_all_tasks(strategy, opts)

  def reorder_tasks_by(strategy, uuids, opts) when is_list(uuids),
    do: permute_tasks_by(strategy, uuids, opts)

  # ---- :all path ------------------------------------------------

  defp reorder_all_projects_in_scope(strategy, is_template?, kind, opts) do
    rows =
      Project
      |> where([p], p.is_template == ^is_template?)
      |> repo().all()

    ordered_uuids = project_strategy_order(rows, strategy)

    case write_project_positions(ordered_uuids) do
      {:ok, count} ->
        log_strategy_reorder(kind, strategy, :all, count, List.first(ordered_uuids), opts)
        :ok

      {:error, reason} ->
        log_reorder_db_error(kind, ordered_uuids, opts)
        {:error, reason}
    end
  end

  defp reorder_all_tasks(strategy, opts) do
    rows = repo().all(Task)
    ordered_uuids = task_strategy_order(rows, strategy)

    case write_task_positions(ordered_uuids) do
      {:ok, count} ->
        log_strategy_reorder("task", strategy, :all, count, List.first(ordered_uuids), opts)
        :ok

      {:error, reason} ->
        log_reorder_db_error("task", ordered_uuids, opts)
        {:error, reason}
    end
  end

  # ---- permute-in-place path -----------------------------------

  defp permute_projects_by(_strategy, uuids, _is_template?, kind, opts)
       when is_list(uuids) and length(uuids) > @reorder_max_uuids do
    log_reorder_rejected(kind, :too_many_uuids, length(uuids), opts)
    {:error, :too_many_uuids}
  end

  defp permute_projects_by(strategy, uuids, is_template?, kind, opts) do
    unique_uuids = dedupe_uuids(uuids)

    case project_scope_check(is_template?, unique_uuids) do
      :empty ->
        :ok

      :ok ->
        rows =
          Project
          |> where([p], p.uuid in ^unique_uuids)
          |> repo().all()

        do_permute_in_place(
          Project,
          rows,
          project_strategy_order(rows, strategy),
          strategy,
          kind,
          opts
        )

      {:error, :wrong_scope} = err ->
        log_reorder_rejected(kind, :wrong_scope, length(unique_uuids), opts)
        err
    end
  end

  defp permute_tasks_by(_strategy, uuids, opts)
       when is_list(uuids) and length(uuids) > @reorder_max_uuids do
    log_reorder_rejected("task", :too_many_uuids, length(uuids), opts)
    {:error, :too_many_uuids}
  end

  defp permute_tasks_by(strategy, uuids, opts) do
    unique_uuids = dedupe_uuids(uuids)

    rows =
      Task
      |> where([t], t.uuid in ^unique_uuids)
      |> repo().all()

    do_permute_in_place(
      Task,
      rows,
      task_strategy_order(rows, strategy),
      strategy,
      "task",
      opts
    )
  end

  defp do_permute_in_place(_schema, [], _ordered_uuids, _strategy, _kind, _opts), do: :ok
  defp do_permute_in_place(_schema, [_], _ordered_uuids, _strategy, _kind, _opts), do: :ok

  defp do_permute_in_place(schema, rows, ordered_uuids, strategy, kind, opts) do
    # `slots` are the positions the selected rows currently occupy,
    # in ascending order. `ordered_uuids` is the same set of uuids
    # in their target order (per strategy). Zipping the two assigns
    # each uuid to the i-th-smallest slot.
    slots = rows |> Enum.map(& &1.position) |> Enum.sort()

    # Untouched rows (DnD-default `position: 0`) collide here: two
    # selected rows with the same current position would receive the
    # same target position in phase 2 and one row's update would
    # silently overwrite the other's intent. Surface as
    # `:duplicate_positions` so the LV can direct the user to
    # "Reorder all" first (which normalises every row to 1..N).
    if slots != Enum.uniq(slots) do
      log_reorder_rejected(kind, :duplicate_positions, length(ordered_uuids), opts)
      {:error, :duplicate_positions}
    else
      pairs = Enum.zip(ordered_uuids, slots)

      case write_permutation(schema, pairs) do
        {:ok, count} ->
          log_strategy_reorder(
            kind,
            strategy,
            :selected,
            count,
            List.first(ordered_uuids),
            opts
          )

          :ok

        {:error, reason} ->
          log_reorder_db_error(kind, ordered_uuids, opts)
          {:error, reason}
      end
    end
  end

  # Two-phase write so the target positions never collide with the
  # rows still holding their pre-write values. Phase 1 stamps
  # negatives (no row currently holds a negative `position`, so the
  # space is empty); phase 2 writes the real target positions.
  #
  # Both phases write in `uuid`-sorted order so two concurrent
  # permute-in-place reorders take row locks in the same deterministic
  # order and can't deadlock against each other (each session would
  # otherwise lock its strategy's first row, then wait on the other's
  # — classic ABBA).
  defp write_permutation(schema, pairs) do
    write_order = Enum.sort_by(pairs, fn {uuid, _pos} -> uuid end)

    repo().transaction(fn ->
      Enum.with_index(write_order, 1)
      |> Enum.each(fn {{uuid, _pos}, idx} ->
        from(r in schema, where: r.uuid == ^uuid)
        |> repo().update_all(set: [position: -idx])
      end)

      Enum.reduce(write_order, 0, fn {uuid, pos}, total ->
        {n, _} =
          from(r in schema, where: r.uuid == ^uuid)
          |> repo().update_all(set: [position: pos])

        total + n
      end)
    end)
  end

  # ---- strategy implementations --------------------------------

  # `inserted_at` is `:utc_datetime` (second precision), so two rows
  # inserted in the same second tie on the primary sort. Each clause
  # below pre-sorts by `:uuid` first — `Enum.sort_by` is stable, so
  # rows with equal primary keys keep this secondary order. UUIDv7 is
  # itself chronological, so an ascending uuid pre-sort puts the newer
  # row last (used for `_asc` strategies) and a descending uuid pre-
  # sort puts it first (used for `_desc` strategies). Net effect on a
  # tie: newer row wins on `_desc`, older row wins on `_asc`.

  defp project_strategy_order(rows, :reverse),
    do: rows |> Enum.sort_by(& &1.position) |> Enum.reverse() |> Enum.map(& &1.uuid)

  defp project_strategy_order(rows, :name_asc) do
    rows
    |> Enum.sort_by(& &1.uuid)
    |> Enum.sort_by(&downcase_or_empty(&1.name))
    |> Enum.map(& &1.uuid)
  end

  defp project_strategy_order(rows, :name_desc) do
    rows
    |> Enum.sort_by(& &1.uuid, :desc)
    |> Enum.sort_by(&downcase_or_empty(&1.name), :desc)
    |> Enum.map(& &1.uuid)
  end

  defp project_strategy_order(rows, :created_asc) do
    rows
    |> Enum.sort_by(& &1.uuid)
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> Enum.map(& &1.uuid)
  end

  defp project_strategy_order(rows, :created_desc) do
    rows
    |> Enum.sort_by(& &1.uuid, :desc)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> Enum.map(& &1.uuid)
  end

  defp task_strategy_order(rows, :reverse),
    do: rows |> Enum.sort_by(& &1.position) |> Enum.reverse() |> Enum.map(& &1.uuid)

  defp task_strategy_order(rows, :name_asc) do
    rows
    |> Enum.sort_by(& &1.uuid)
    |> Enum.sort_by(&downcase_or_empty(&1.title))
    |> Enum.map(& &1.uuid)
  end

  defp task_strategy_order(rows, :name_desc) do
    rows
    |> Enum.sort_by(& &1.uuid, :desc)
    |> Enum.sort_by(&downcase_or_empty(&1.title), :desc)
    |> Enum.map(& &1.uuid)
  end

  defp task_strategy_order(rows, :created_asc) do
    rows
    |> Enum.sort_by(& &1.uuid)
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> Enum.map(& &1.uuid)
  end

  defp task_strategy_order(rows, :created_desc) do
    rows
    |> Enum.sort_by(& &1.uuid, :desc)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> Enum.map(& &1.uuid)
  end

  defp downcase_or_empty(nil), do: ""
  defp downcase_or_empty(s) when is_binary(s), do: String.downcase(s)

  # Bulk strategy reorders share the same action name as DnD reorders
  # (`<kind>.reordered`) so downstream readers (admin activity feed,
  # exports) can treat them as one event class. The `mechanism` /
  # `strategy` / `scope` metadata distinguishes them when needed.
  defp log_strategy_reorder(kind, strategy, scope, count, first_uuid, opts) do
    extra = Keyword.get(opts, :metadata, %{})

    log_activity(%{
      action: "#{kind}.reordered",
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: kind,
      resource_uuid: first_uuid,
      metadata:
        Map.merge(
          %{
            "count" => count,
            "mechanism" => "strategy",
            "strategy" => Atom.to_string(strategy),
            "scope" => Atom.to_string(scope)
          },
          extra
        )
    })
  end
end
