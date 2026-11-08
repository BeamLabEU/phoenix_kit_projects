defmodule PhoenixKitProjects.TaskConversion do
  @moduledoc """
  A task made a sub-project, and a sub-project made a task — **in place**
  (the boss, 2026-10-30: "what if they suddenly want more complexity on a
  task?"; the panel of 2026-10-31 chose this over a copy).

  The row keeps its identity either way: its uuid, its place in the list,
  its connections, comments, files, logged time and history all stay
  where they are, because they hang off the row and the row is not
  replaced.

    * `to_subproject/2` — a child project is made from the task (its
      name, description and assignees; the deadline stays on the row), the
      task's subtasks become the child's tasks (with what is under them),
      and the row becomes the sub-project's row.
    * `to_task/2` — the child's tasks come back as subtasks of the row
      (subtasks are whole tasks here, so nothing is lost), the row becomes
      a task again named after the child, and the child project is
      **archived**, never deleted: its members and settings can come back.

  Each runs in one transaction under the parent project's lock
  (`Outline.with_project_lock/2`). A moved task gets the next free number
  of the project it moves to (`KEY-n` is per project), and the time logged
  on it moves with it. Connections between a moved task and one that
  stays are kept as they are.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.{AssigneeSet, Outline, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Project, Task, WorkEntry}

  @prefix Application.compile_env(:phoenix_kit, :prefix)
  @counters "phoenix_kit_project_task_counters"

  defp repo, do: RepoHelper.repo()

  @typedoc "What a conversion moved."
  @type result :: %{assignment: Assignment.t(), project: Project.t(), moved: non_neg_integer()}

  # ── Task → sub-project ─────────────────────────────────────────────

  @doc """
  Makes the task `row` a sub-project of its project.

  Errors: `:not_a_task` (already a sub-project), `:subtask` (a sub-project
  row sits at the top of the list), `:too_deep` (the tree has no room for
  another level), `:not_found`, or a changeset.
  """
  @spec to_subproject(Assignment.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def to_subproject(row, opts \\ [])

  def to_subproject(%Assignment{child_project_uuid: child}, _opts) when is_binary(child),
    do: {:error, :not_a_task}

  # A sub-project row sits at the top of its project's list.
  def to_subproject(%Assignment{parent_uuid: parent}, _opts) when is_binary(parent),
    do: {:error, :subtask}

  def to_subproject(%Assignment{} = row, opts) do
    result =
      Outline.with_project_lock(row.project_uuid, fn parent ->
        with %Assignment{child_project_uuid: nil} = row <- fresh(row),
             :ok <- room_below(parent) do
          rows = project_rows(parent.uuid)
          moving = Outline.descendants(rows, row.uuid)

          child = insert_child!(parent, row, opts)
          move_rows!(moving, child.uuid, under: {row.uuid, nil}, after_position: 0)

          link =
            row
            # A sub-project row does not come back as a next occurrence
            # (`Repeats` copies a task): the rule stays behind, or every
            # finish of the sub-project would try to repeat it and fail.
            |> Ecto.Changeset.change(
              task_uuid: nil,
              child_project_uuid: child.uuid,
              repeat_rule: nil
            )
            |> Ecto.Changeset.check_constraint(:child_project_uuid,
              name: :phoenix_kit_project_assignments_task_xor_child
            )
            |> repo().update!()

          %{assignment: link, project: child, moved: length(moving)}
        else
          {:error, reason} -> repo().rollback(reason)
          %Assignment{} -> repo().rollback(:not_a_task)
          nil -> repo().rollback(:not_found)
        end
      end)

    with {:ok, %{project: child} = done} <- result do
      # Ongoing work is started as it is made, and the row's figures come
      # from its new project from now on (`Projects`' rollup).
      {:ok, child} = Projects.start_ongoing({:ok, child})
      Projects.recompute_project_completion(child.uuid)
      announce(row.project_uuid, child.uuid, row.uuid)
      Projects.broadcast_project_updated(child)
      {:ok, %{done | project: child, assignment: Projects.get_assignment(row.uuid)}}
    end
  end

  # A sub-project one level below the parent must still fit the tree — the
  # limit `parent_chain/1` walks (8), not the tree builders' 32, against
  # which this check could never refuse.
  defp room_below(%Project{} = parent) do
    if Projects.room_for_subproject?(parent), do: :ok, else: {:error, :too_deep}
  end

  # The child: named and described as the task, the task's assignee, the
  # parent's completion mode and template-ness (as `create_subproject/2`).
  defp insert_child!(%Project{} = parent, %Assignment{} = row, opts) do
    task = row.task || (row.task_uuid && repo().get(Task, row.task_uuid))

    settings =
      if Project.completion(parent) == "manual", do: %{"completion" => "manual"}, else: %{}

    attrs = %{
      "name" => (task && task.title) || Assignment.label(row),
      "description" => row.description || (task && task.description),
      "translations" => child_translations(task),
      "is_template" => to_string(parent.is_template),
      "start_mode" => "immediate",
      "settings" => settings,
      # The task's whole set (V30: a project has any number too); the row
      # keeps its own as well, as it keeps its other things.
      "assignees" => AssigneeSet.keys(row)
    }

    # Announced once the move has committed (`broadcast_project_updated/1`).
    case Projects.create_project(attrs,
           actor_uuid: Keyword.get(opts, :actor_uuid),
           broadcast: false
         ) do
      {:ok, child} -> child
      {:error, cs} -> repo().rollback(cs)
    end
  end

  # A task's title is the project's name in each language it has one.
  defp child_translations(%Task{translations: %{} = t}) do
    Map.new(t, fn {lang, fields} ->
      {lang,
       fields
       |> Map.take(["title", "description"])
       |> Map.new(fn
         {"title", v} -> {"name", v}
         kv -> kv
       end)}
    end)
  end

  defp child_translations(_task), do: %{}

  # ── Sub-project → task ─────────────────────────────────────────────

  @doc """
  Makes the sub-project row `link` a task again: the child project's tasks
  become its subtasks and the child project is archived.

  Errors: `:not_a_subproject`, `:has_subprojects` (the child holds
  sub-projects of its own, which cannot sit under a task), `:not_found`,
  or a changeset.
  """
  @spec to_task(Assignment.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def to_task(link, opts \\ [])

  def to_task(%Assignment{child_project_uuid: nil}, _opts), do: {:error, :not_a_subproject}

  def to_task(%Assignment{} = link, _opts) do
    result =
      Outline.with_project_lock(link.project_uuid, fn _parent ->
        with %Assignment{child_project_uuid: child_uuid} = link when is_binary(child_uuid) <-
               fresh(link),
             %Project{} = child <- repo().get(Project, child_uuid),
             rows = project_rows(child.uuid),
             :ok <- no_subprojects(rows) do
          task = insert_task!(child)

          # Room after the row: what follows it moves down by as many rows
          # as come in, so they sit right under it, depth first.
          n = length(rows)

          if n > 0 do
            from(a in Assignment,
              where: a.project_uuid == ^link.project_uuid and a.position > ^link.position
            )
            |> repo().update_all(inc: [position: n])
          end

          move_rows!(rows, link.project_uuid,
            under: {nil, link.uuid},
            after_position: link.position
          )

          # The row keeps its own assignees; with none it takes the
          # project's (V30: its whole set, mirror included).
          keys =
            case AssigneeSet.keys(link) do
              [] -> AssigneeSet.keys(child)
              own -> own
            end

          AssigneeSet.write_rows(repo(), link.uuid, keys)

          row =
            link
            |> Ecto.Changeset.change(
              Map.to_list(AssigneeSet.mirror(keys)) ++
                [task_uuid: task.uuid, child_project_uuid: nil]
            )
            |> Ecto.Changeset.check_constraint(:child_project_uuid,
              name: :phoenix_kit_project_assignments_task_xor_child
            )
            |> repo().update!()

          archived =
            case child
                 |> Project.changeset(%{archived_at: DateTime.utc_now()})
                 |> repo().update() do
              {:ok, archived} -> archived
              {:error, cs} -> repo().rollback(cs)
            end

          # The rows that came in may tick or reopen the row (the
          # completion rules); `settle_tree/2` must run under the lock.
          Outline.settle_tree(link.project_uuid)

          %{assignment: row, project: archived, moved: n}
        else
          {:error, reason} -> repo().rollback(reason)
          %Assignment{} -> repo().rollback(:not_a_subproject)
          nil -> repo().rollback(:not_found)
        end
      end)

    with {:ok, %{project: child} = done} <- result do
      Projects.recompute_project_completion(link.project_uuid)
      announce(link.project_uuid, child.uuid, link.uuid)
      Projects.broadcast_project_updated(child)
      {:ok, %{done | assignment: Projects.get_assignment(link.uuid)}}
    end
  end

  # Nothing may sit under a sub-project row inside a task's subtree.
  defp no_subprojects(rows) do
    if Enum.any?(rows, &is_binary(&1.child_project_uuid)),
      do: {:error, :has_subprojects},
      else: :ok
  end

  # The task the row points at again: the child's name and description,
  # in every language it has them. One-off, not a library task.
  defp insert_task!(%Project{} = child) do
    translations =
      Map.new(child.translations || %{}, fn {lang, fields} ->
        {lang,
         fields
         |> Map.take(["name", "description"])
         |> Map.new(fn
           {"name", v} -> {"title", v}
           kv -> kv
         end)}
      end)

    attrs = %{
      "title" => child.name,
      "description" => child.description,
      "translations" => translations,
      "ad_hoc" => true
    }

    case %Task{} |> Task.changeset(attrs) |> repo().insert() do
      {:ok, task} -> task
      {:error, cs} -> repo().rollback(cs)
    end
  end

  # ── Moving rows between projects ───────────────────────────────────

  # Moves `rows` (depth first) into `project_uuid`: placed one after the
  # other after `after_position`, given the project's next free numbers,
  # their logged time with them. `under: {from, to}` — a row sitting
  # directly under `from` comes to sit under `to` (nil: the top level);
  # deeper rows keep their parent, which moves too.
  #
  # The parents are cleared first and set again after the move: the
  # database refuses a parent in another project at every write, and the
  # rows cannot all move in one statement.
  defp move_rows!([], _project_uuid, _opts), do: :ok

  defp move_rows!(rows, project_uuid, opts) do
    {from, to} = Keyword.fetch!(opts, :under)
    start = Keyword.fetch!(opts, :after_position)
    uuids = Enum.map(rows, & &1.uuid)
    first = next_numbers!(project_uuid, length(rows))

    from(a in Assignment, where: a.uuid in ^uuids) |> repo().update_all(set: [parent_uuid: nil])

    rows
    |> Enum.with_index()
    |> Enum.each(fn {row, i} ->
      from(a in Assignment, where: a.uuid == ^row.uuid)
      |> repo().update_all(
        set: [project_uuid: project_uuid, number: first + i, position: start + i + 1]
      )
    end)

    rows
    |> Enum.map(fn row ->
      {row.uuid, if(row.parent_uuid == from, do: to, else: row.parent_uuid)}
    end)
    |> Enum.reject(fn {_uuid, parent} -> is_nil(parent) end)
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.each(fn {parent, children} ->
      from(a in Assignment, where: a.uuid in ^children)
      |> repo().update_all(set: [parent_uuid: parent])
    end)

    from(w in WorkEntry, where: w.assignment_uuid in ^uuids)
    |> repo().update_all(set: [project_uuid: project_uuid])

    :ok
  end

  # `count` numbers of `project_uuid` nobody holds: the counter moves on
  # by `count` (the same counter the numbering trigger keeps) and the first
  # of them comes back.
  defp next_numbers!(project_uuid, count) do
    {:ok, dumped} = Ecto.UUID.dump(project_uuid)

    {1, [%{last_number: last}]} =
      repo().insert_all(
        @counters,
        [%{project_uuid: dumped, last_number: count}],
        on_conflict: [inc: [last_number: count]],
        conflict_target: [:project_uuid],
        returning: [:last_number],
        prefix: @prefix
      )

    last - count + 1
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp fresh(%Assignment{uuid: uuid}) do
    Assignment |> preload(:task) |> repo().get(uuid)
  end

  # The project's rows in list order — the depth-first walk the outline
  # keeps in `position`.
  defp project_rows(project_uuid) do
    from(a in Assignment,
      where: a.project_uuid == ^project_uuid,
      order_by: [asc: a.position, asc: a.inserted_at]
    )
    |> repo().all()
  end

  defp announce(parent_uuid, child_uuid, row_uuid) do
    ProjectsPubSub.broadcast_assignment(:assignment_updated, %{
      uuid: row_uuid,
      project_uuid: parent_uuid
    })

    for project_uuid <- [parent_uuid, child_uuid] do
      ProjectsPubSub.broadcast_assignment(:assignment_reordered, %{project_uuid: project_uuid})
    end

    :ok
  end
end
