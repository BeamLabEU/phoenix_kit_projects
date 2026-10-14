defmodule PhoenixKitProjects.Outline do
  @moduledoc """
  A project's tasks as an outline: tasks under tasks (chain V23).

  A task may sit under another task of the same project, to any depth. Two
  columns say where a row is: `parent_uuid` (what it sits under) and
  `position` — ONE order for the whole project, written depth first, so a
  parent is followed by everything under it. Readers that only sort by
  `position` therefore keep a sensible order; readers that need the shape
  call `walk/1`.

  Three kinds of thing live here:

    * **reading the shape** — `walk/1`, `leaves/1`, `descendants/2`,
      `counts/1`: pure functions over a list of rows;
    * **the completion rules** — `settle/3`, called by every path that
      changes a task's status: ticking a task ticks everything under it;
      a task whose last subtask is ticked ticks itself (a project setting);
      a subtask reopened reopens what it sits under; unticking a task
      touches nothing below it;
    * **writing the shape** — `write_order/2`, `move/3`, and `sync/4`, the
      one write behind the typed task list: the list as the browser has it
      (one line per task, an indent per level) is reconciled against the
      rows — new lines become tasks, changed lines are renamed, the order
      and the nesting are rewritten, and a line that is gone is deleted or,
      when it carries something, held (`review_status: "removed"`).
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Project, Task}

  @type row :: Assignment.t() | %{uuid: binary(), parent_uuid: binary() | nil}

  @max_lines 2000
  @title_max 500

  defp repo, do: RepoHelper.repo()

  # ── Reading the shape ──────────────────────────────────────────────

  @doc """
  The rows depth first, each with its depth (0 at the top): `[{row, depth}]`.
  Siblings keep the order they arrive in (callers pass `position` order). A
  row whose parent is not among `rows` (filtered out, held, another page) is
  shown at the top level rather than dropped.
  """
  @spec walk([row()]) :: [{row(), non_neg_integer()}]
  def walk(rows) do
    present = MapSet.new(rows, & &1.uuid)
    by_parent = Enum.group_by(rows, &effective_parent(&1, present))
    do_walk(Map.get(by_parent, nil, []), by_parent, 0, MapSet.new()) |> elem(0) |> Enum.reverse()
  end

  defp effective_parent(%{parent_uuid: parent}, present) do
    if parent && MapSet.member?(present, parent), do: parent, else: nil
  end

  defp do_walk(rows, by_parent, depth, seen) do
    Enum.reduce(rows, {[], seen}, fn row, {acc, seen} ->
      if MapSet.member?(seen, row.uuid) do
        {acc, seen}
      else
        seen = MapSet.put(seen, row.uuid)
        {below, seen} = do_walk(Map.get(by_parent, row.uuid, []), by_parent, depth + 1, seen)
        {below ++ [{row, depth} | acc], seen}
      end
    end)
  end

  @doc "Depth of every row, by uuid."
  @spec depths([row()]) :: %{binary() => non_neg_integer()}
  def depths(rows), do: rows |> walk() |> Map.new(fn {row, depth} -> {row.uuid, depth} end)

  @doc "The uuids that have something under them, among `rows`."
  @spec parents([row()]) :: MapSet.t(binary())
  def parents(rows) do
    present = MapSet.new(rows, & &1.uuid)

    rows
    |> Enum.map(& &1.parent_uuid)
    |> Enum.filter(&(&1 && MapSet.member?(present, &1)))
    |> MapSet.new()
  end

  @doc """
  The rows that are work to count: those with nothing under them. A task
  with subtasks is the sum of them, so counting it as well would make one
  piece of work read as two.
  """
  @spec leaves([row()]) :: [row()]
  def leaves(rows) do
    parents = parents(rows)
    Enum.reject(rows, &MapSet.member?(parents, &1.uuid))
  end

  @doc "Top-level rows only (a row whose parent is not in `rows` counts as top-level)."
  @spec roots([row()]) :: [row()]
  def roots(rows) do
    present = MapSet.new(rows, & &1.uuid)
    Enum.filter(rows, &is_nil(effective_parent(&1, present)))
  end

  @doc "Everything under `uuid`, depth first, among `rows`."
  @spec descendants([row()], binary()) :: [row()]
  def descendants(rows, uuid) do
    by_parent = Enum.group_by(rows, & &1.parent_uuid)

    do_walk(Map.get(by_parent, uuid, []), by_parent, 0, MapSet.new([uuid]))
    |> elem(0)
    |> Enum.reverse()
    |> Enum.map(&elem(&1, 0))
  end

  @doc "The chain above `uuid`, nearest first, among `rows`."
  @spec ancestors([row()], binary()) :: [row()]
  def ancestors(rows, uuid) do
    by_uuid = Map.new(rows, &{&1.uuid, &1})
    do_ancestors(by_uuid, Map.get(by_uuid, uuid), [], 0)
  end

  defp do_ancestors(_by_uuid, nil, acc, _hops), do: Enum.reverse(acc)
  defp do_ancestors(_by_uuid, _row, acc, hops) when hops > 100, do: Enum.reverse(acc)

  defp do_ancestors(by_uuid, %{parent_uuid: parent}, acc, hops) do
    case parent && Map.get(by_uuid, parent) do
      nil -> Enum.reverse(acc)
      up -> do_ancestors(by_uuid, up, [up | acc], hops + 1)
    end
  end

  @doc """
  For every row that has something under it: how many of the tasks at the
  bottom of its branch are done, and how many there are —
  `%{uuid => %{done: n, total: n}}`. "3 of 7" on a parent row.
  """
  @spec counts([Assignment.t()]) :: %{
          binary() => %{done: non_neg_integer(), total: non_neg_integer()}
        }
  def counts(rows) do
    by_parent = Enum.group_by(rows, & &1.parent_uuid)

    rows
    |> Enum.filter(&Map.has_key?(by_parent, &1.uuid))
    |> Map.new(fn row ->
      below = do_walk(Map.get(by_parent, row.uuid, []), by_parent, 0, MapSet.new([row.uuid]))

      leaves =
        below
        |> elem(0)
        |> Enum.map(&elem(&1, 0))
        |> Enum.reject(&Map.has_key?(by_parent, &1.uuid))

      {row.uuid, %{done: Enum.count(leaves, &(&1.status == "done")), total: length(leaves)}}
    end)
  end

  @doc "The accepted rows of a project in outline order — uuid, parent, status and kind only."
  @spec shape(binary()) :: [map()]
  def shape(project_uuid) when is_binary(project_uuid) do
    from(a in Assignment,
      where: a.project_uuid == ^project_uuid and a.review_status == "accepted",
      order_by: [asc: a.position, asc: a.inserted_at],
      select: %{
        uuid: a.uuid,
        parent_uuid: a.parent_uuid,
        status: a.status,
        position: a.position,
        child_project_uuid: a.child_project_uuid,
        assigned_person_uuid: a.assigned_person_uuid
      }
    )
    |> repo().all()
  end

  @doc "How many accepted rows sit under this task (any depth)."
  @spec descendant_count(Assignment.t()) :: non_neg_integer()
  def descendant_count(%Assignment{uuid: uuid, project_uuid: project_uuid}) do
    project_uuid |> shape() |> descendants(uuid) |> length()
  end

  @doc """
  What ticking this task would tick with it: the open tasks under it —
  `%{count, others}`, `others` being how many of those are assigned to a
  person other than `person_uuid`. The list asks before ticking other
  people's work.
  """
  @spec open_below(Assignment.t(), binary() | nil) :: %{
          count: non_neg_integer(),
          others: non_neg_integer()
        }
  def open_below(%Assignment{uuid: uuid, project_uuid: project_uuid}, person_uuid \\ nil) do
    open =
      project_uuid
      |> shape()
      |> descendants(uuid)
      |> Enum.filter(&(&1.status != "done" and is_nil(&1.child_project_uuid)))

    %{
      count: length(open),
      others:
        Enum.count(open, &(&1.assigned_person_uuid && &1.assigned_person_uuid != person_uuid))
    }
  end

  # ── The completion rules ───────────────────────────────────────────

  @doc """
  Settles the rows around a task whose status just changed from `was` to
  its current one. `actor_uuid` is who did it (stamped on what gets ticked).

    * became done → every open task under it is ticked too (a sub-project
      row is left to its own project);
    * became done → each task above whose subtasks are now all done ticks
      itself, when the project lets subtasks complete their parent;
    * stopped being done → every done task above reopens.

  Returns the uuids of the OTHER rows it changed. No broadcast: the caller
  owns that.
  """
  @spec settle(Assignment.t(), String.t() | nil, binary() | nil) :: [binary()]
  def settle(%Assignment{} = a, was, actor_uuid \\ nil) do
    cond do
      a.status == "done" and was != "done" ->
        down = tick_below(a, actor_uuid)
        down ++ settle_above(a, actor_uuid)

      a.status != "done" and was == "done" ->
        reopen_above(a)

      true ->
        []
    end
  end

  @doc """
  After a task was added, moved or removed: what it now sits under (or no
  longer does) is brought in line — an open task under a done one reopens
  it. Returns the uuids changed.
  """
  @spec settle_placed(Assignment.t()) :: [binary()]
  def settle_placed(%Assignment{status: "done"}), do: []
  def settle_placed(%Assignment{} = a), do: reopen_above(a)

  defp tick_below(%Assignment{} = a, actor_uuid) do
    uuids =
      a.project_uuid
      |> shape()
      |> descendants(a.uuid)
      |> Enum.filter(&(&1.status != "done" and is_nil(&1.child_project_uuid)))
      |> Enum.map(& &1.uuid)

    mark_done(uuids, actor_uuid)
  end

  defp settle_above(%Assignment{} = a, actor_uuid) do
    if parent_auto?(a.project_uuid) do
      rows = shape(a.project_uuid)
      climb(rows, a.uuid, actor_uuid, [])
    else
      []
    end
  end

  # One level at a time: a parent whose rows are all done is ticked, and
  # then stands as a done row for the level above it.
  defp climb(rows, uuid, actor_uuid, acc) do
    by_uuid = Map.new(rows, &{&1.uuid, &1})

    with %{parent_uuid: parent_uuid} when is_binary(parent_uuid) <- Map.get(by_uuid, uuid),
         %{status: status, child_project_uuid: nil} = parent when status != "done" <-
           Map.get(by_uuid, parent_uuid),
         true <-
           rows
           |> Enum.filter(&(&1.parent_uuid == parent_uuid))
           |> Enum.all?(&(&1.status == "done")) do
      mark_done([parent.uuid], actor_uuid)

      rows =
        Enum.map(rows, fn
          %{uuid: ^parent_uuid} = row -> %{row | status: "done"}
          row -> row
        end)

      climb(rows, parent_uuid, actor_uuid, [parent_uuid | acc])
    else
      _ -> acc
    end
  end

  defp reopen_above(%Assignment{} = a) do
    rows = shape(a.project_uuid)

    done_above =
      rows
      |> ancestors(a.uuid)
      |> Enum.filter(&(&1.status == "done" and is_nil(&1.child_project_uuid)))
      |> Enum.map(& &1.uuid)

    if done_above == [] do
      []
    else
      # Under way, not untouched: something below it was done or is.
      from(x in Assignment, where: x.uuid in ^done_above)
      |> repo().update_all(
        set: [
          status: "in_progress",
          completed_at: nil,
          completed_by_uuid: nil,
          updated_at: now()
        ]
      )

      done_above
    end
  end

  defp mark_done([], _actor_uuid), do: []

  defp mark_done(uuids, actor_uuid) do
    from(x in Assignment, where: x.uuid in ^uuids and x.status != "done")
    |> repo().update_all(
      set: [
        status: "done",
        progress_pct: 100,
        completed_at: now(),
        completed_by_uuid: actor_uuid,
        waiting_on: nil,
        updated_at: now()
      ]
    )

    uuids
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc """
  Whether a task ticks itself when its last subtask is ticked — the
  project's `subtasks.complete_parent` setting, on unless turned off (a
  parent can carry work of its own that the subtasks do not cover).
  """
  @spec parent_auto?(Project.t() | binary() | nil) :: boolean()
  def parent_auto?(%{settings: settings}) when is_map(settings) do
    case settings do
      %{"outline" => %{"complete_parent" => false}} -> false
      _ -> true
    end
  end

  def parent_auto?(project_uuid) when is_binary(project_uuid) do
    repo().one(from(p in Project, where: p.uuid == ^project_uuid, select: p.settings))
    |> then(&parent_auto?(%{settings: &1 || %{}}))
  end

  def parent_auto?(_), do: true

  # ── Writing the shape ──────────────────────────────────────────────

  @doc """
  Writes a project's outline: `order` is every row to place, depth first,
  as `{uuid, parent_uuid | nil}`. Rows of the project that `order` does not
  name keep their parent and are placed after it. Only rows that actually
  move are written. Must run inside a transaction that holds the project
  lock (`with_project_lock/2`).
  """
  @spec write_order(binary(), [{binary(), binary() | nil}]) :: :ok
  def write_order(project_uuid, order) when is_binary(project_uuid) and is_list(order) do
    current =
      from(a in Assignment,
        where: a.project_uuid == ^project_uuid,
        order_by: [asc: a.position, asc: a.inserted_at],
        select: {a.uuid, a.parent_uuid, a.position}
      )
      |> repo().all()

    named = MapSet.new(order, &elem(&1, 0))

    rest =
      for {uuid, parent, _pos} <- current, not MapSet.member?(named, uuid), do: {uuid, parent}

    wanted =
      (order ++ rest)
      |> Enum.with_index(1)
      |> Map.new(fn {{uuid, parent}, position} -> {uuid, {parent, position}} end)

    reparented =
      for {uuid, parent, _pos} <- current,
          {new_parent, _} = Map.fetch!(wanted, uuid),
          new_parent != parent,
          do: {uuid, new_parent}

    # Cleared first, then set: a batch that swaps two rows' places must
    # never pass through a moment where each sits under the other.
    if reparented != [] do
      from(a in Assignment, where: a.uuid in ^Enum.map(reparented, &elem(&1, 0)))
      |> repo().update_all(set: [parent_uuid: nil])

      reparented
      |> Enum.reject(fn {_uuid, parent} -> is_nil(parent) end)
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
      |> Enum.each(fn {parent, uuids} ->
        from(a in Assignment, where: a.uuid in ^uuids)
        |> repo().update_all(set: [parent_uuid: parent])
      end)
    end

    for {uuid, _parent, position} <- current,
        {_, new_position} = Map.fetch!(wanted, uuid),
        new_position != position do
      from(a in Assignment, where: a.uuid == ^uuid)
      |> repo().update_all(set: [position: new_position])
    end

    :ok
  end

  @doc "Runs `fun` in a transaction holding the project's row lock; `{:error, :not_found}` without the project."
  @spec with_project_lock(binary(), (Project.t() -> any())) :: {:ok, any()} | {:error, any()}
  def with_project_lock(project_uuid, fun) do
    repo().transaction(fn ->
      case repo().one(from(p in Project, where: p.uuid == ^project_uuid, lock: "FOR UPDATE")) do
        nil -> repo().rollback(:not_found)
        project -> fun.(project)
      end
    end)
  end

  @doc """
  Moves a task — with everything under it — to sit under `parent_uuid`
  (nil: the top level), right after the sibling `after_uuid` (nil: first
  under that parent; `:last`: after its last sibling).

  `{:error, :not_found}` for a parent or sibling that is not an accepted
  row of the same project, `{:error, :cycle}` for a place under itself.
  Broadcasts `:assignment_reordered`.
  """
  @spec move(Assignment.t(), binary() | nil, binary() | nil | :last) ::
          {:ok, Assignment.t()} | {:error, :not_found | :cycle | term()}
  def move(%Assignment{} = a, parent_uuid, after_uuid \\ :last) do
    result =
      with_project_lock(a.project_uuid, fn _project ->
        rows = shape(a.project_uuid)
        by_uuid = Map.new(rows, &{&1.uuid, &1})
        branch = [a.uuid | rows |> descendants(a.uuid) |> Enum.map(& &1.uuid)]

        cond do
          not Map.has_key?(by_uuid, a.uuid) ->
            repo().rollback(:not_found)

          parent_uuid && not Map.has_key?(by_uuid, parent_uuid) ->
            repo().rollback(:not_found)

          parent_uuid in branch ->
            repo().rollback(:cycle)

          is_binary(after_uuid) and
              (not Map.has_key?(by_uuid, after_uuid) or after_uuid in branch or
                 by_uuid[after_uuid].parent_uuid != parent_uuid) ->
            repo().rollback(:not_found)

          true ->
            moved =
              Enum.map(
                rows,
                &if(&1.uuid == a.uuid, do: %{&1 | parent_uuid: parent_uuid}, else: &1)
              )

            {mine, others} = Enum.split_with(moved, &(&1.uuid in branch))
            siblings = Enum.filter(others, &(&1.parent_uuid == parent_uuid))

            # The row the branch goes after, among everything that stays.
            anchor =
              case after_uuid do
                nil -> parent_uuid
                :last -> last_of(others, List.last(siblings), parent_uuid)
                uuid -> last_of(others, by_uuid[uuid], parent_uuid)
              end

            placed = insert_after(walk(others), walk_branch(mine, a.uuid), anchor)
            write_order(a.project_uuid, Enum.map(placed, &{&1.uuid, &1.parent_uuid}))
            repo().get!(Assignment, a.uuid)
        end
      end)

    with {:ok, moved} <- result do
      settle_placed(moved)

      ProjectsPubSub.broadcast_assignment(:assignment_reordered, %{
        project_uuid: moved.project_uuid
      })

      {:ok, moved}
    end
  end

  # The last row of `sibling`'s branch (the row itself when nothing is under
  # it); with no sibling, the parent — "first under it".
  defp last_of(_rows, nil, parent_uuid), do: parent_uuid

  defp last_of(rows, sibling, _parent_uuid) do
    case rows |> descendants(sibling.uuid) |> List.last() do
      nil -> sibling.uuid
      last -> last.uuid
    end
  end

  defp walk_branch(rows, root_uuid) do
    root = Enum.find(rows, &(&1.uuid == root_uuid))
    [root | descendants(rows, root_uuid)]
  end

  defp insert_after(walked, branch, nil), do: branch ++ Enum.map(walked, &elem(&1, 0))

  defp insert_after(walked, branch, anchor) do
    Enum.flat_map(walked, fn {row, _depth} ->
      if row.uuid == anchor, do: [row | branch], else: [row]
    end)
  end

  # ── The typed list ─────────────────────────────────────────────────

  @doc """
  Reconciles the task list as a browser has it with the project's rows —
  the one write behind the typed list.

  `lines` is the whole list, top to bottom: `%{"id" => uuid | nil, "tmp" =>
  client key for a new line, "text" => title, "depth" => indent level}`.
  `known` is every task uuid that browser has been shown: only a task it
  knew about and no longer lists is taken as removed, so a task someone
  else added a moment ago is never deleted by a list that had not heard of
  it yet.

    * a line with no id (or an id that is not this project's) → a new
      one-off task;
    * a line whose text differs from its task's title → renamed;
    * a line carrying the id of a held task → the task is back, in the
      place the line stands (a cut that was pasted);
    * a known task with no line → deleted when nothing hangs on it, held
      when something does (`protected?/2`);
    * the order and the nesting follow the lines; a depth more than one
      below the line above is pulled up to that.

  Sub-project rows are never removed here, whatever the lines say.

  Options: `:actor_uuid` (stamped as creator), `:key_uuid` (an API key as
  the writer), `:rename` (false: titles of existing tasks are left alone).

  Returns `{:ok, %{created: %{tmp => %{uuid, number}}, removed: [uuid],
  held: [uuid], revived: [uuid], renamed: [uuid]}}`, or `{:error, reason}`
  (`:too_many_lines`, `:not_found`, or `{:line, index, changeset}`).
  Broadcasts one `:assignment_reordered` for the project after commit.
  """
  @spec sync(binary(), [map()], [binary()], keyword()) :: {:ok, map()} | {:error, term()}
  def sync(project_uuid, lines, known, opts \\ [])

  def sync(_project_uuid, lines, _known, _opts) when length(lines) > @max_lines,
    do: {:error, :too_many_lines}

  def sync(project_uuid, lines, known, opts) when is_binary(project_uuid) and is_list(lines) do
    result = with_project_lock(project_uuid, &do_sync(&1, lines, MapSet.new(known), opts))

    with {:ok, summary} <- result do
      Enum.each(summary.renamed_tasks, fn {_row_uuid, task} ->
        ProjectsPubSub.broadcast_task(:task_updated, %{uuid: task.uuid, title: task.title})
      end)

      ProjectsPubSub.broadcast_assignment(:assignment_reordered, %{project_uuid: project_uuid})
      {:ok, Map.delete(summary, :renamed_tasks)}
    end
  end

  defp do_sync(project, lines, known, opts) do
    rows =
      from(a in Assignment,
        where: a.project_uuid == ^project.uuid and a.review_status in ["accepted", "removed"],
        order_by: [asc: a.position, asc: a.inserted_at],
        preload: [:task]
      )
      |> repo().all()

    by_uuid = Map.new(rows, &{&1.uuid, &1})

    lines = normalize_lines(lines, by_uuid)

    # 1. New lines become tasks.
    {lines, created} = create_lines(project, lines, opts)

    # 2. Held tasks that a line names are back.
    revived =
      for %{id: id} <- lines, row = by_uuid[id], row && row.review_status == "removed", do: id

    if revived != [] do
      from(a in Assignment, where: a.uuid in ^revived)
      |> repo().update_all(set: [review_status: "accepted", updated_at: now()])
    end

    # 3. Changed titles.
    renamed_tasks =
      if Keyword.get(opts, :rename, true), do: rename_lines(lines, by_uuid, opts), else: []

    # 4. Known tasks with no line.
    listed = MapSet.new(lines, & &1.id)

    gone =
      Enum.filter(rows, fn row ->
        row.review_status == "accepted" and is_nil(row.child_project_uuid) and
          MapSet.member?(known, row.uuid) and not MapSet.member?(listed, row.uuid)
      end)

    {removed, held} = remove_rows(gone, rows, listed)

    # 5. The order and the nesting.
    unlisted =
      Enum.filter(rows, fn row ->
        row.review_status == "accepted" and not MapSet.member?(listed, row.uuid) and
          row.uuid not in removed and row.uuid not in held
      end)

    order = lines |> nest() |> weave(unlisted, rows)
    write_order(project.uuid, order)

    %{
      created: created,
      removed: removed,
      held: held,
      revived: revived,
      renamed: Enum.map(renamed_tasks, &elem(&1, 0)),
      renamed_tasks: renamed_tasks
    }
  end

  # Blank new lines are not tasks; an id seen twice (a line split by the
  # browser carries its id onto both halves) stays with the first; an id
  # that is not this project's is a new line.
  defp normalize_lines(lines, by_uuid) do
    {out, _seen} =
      Enum.reduce(lines, {[], MapSet.new()}, fn line, {acc, seen} ->
        id = line["id"]
        text = line["text"] |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()
        text = String.slice(text, 0, @title_max)
        depth = line["depth"] |> to_int() |> max(0)

        id =
          if is_binary(id) and Map.has_key?(by_uuid, id) and not MapSet.member?(seen, id), do: id

        cond do
          text == "" and is_nil(id) ->
            {acc, seen}

          # A task whose title was emptied is a task taken out.
          text == "" and is_nil(by_uuid[id].child_project_uuid) ->
            {acc, seen}

          true ->
            entry = %{
              id: id,
              tmp: line["tmp"],
              text: text,
              depth: depth,
              done: line["done"] == true
            }

            {[entry | acc], if(id, do: MapSet.put(seen, id), else: seen)}
        end
      end)

    Enum.reverse(out)
  end

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  defp create_lines(project, lines, opts) do
    actor_uuid = Keyword.get(opts, :actor_uuid)
    key_uuid = Keyword.get(opts, :key_uuid)

    {lines, created} =
      lines
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn
        {%{id: nil} = line, index}, created ->
          task =
            insert!(index, Task.changeset(%Task{}, %{"title" => line.text, "ad_hoc" => true}))

          status = if line.done, do: "done", else: "todo"

          assignment =
            insert!(
              index,
              %Assignment{}
              |> Assignment.status_changeset(%{
                "project_uuid" => project.uuid,
                "task_uuid" => task.uuid,
                "status" => status,
                "progress_pct" => if(line.done, do: 100, else: 0),
                "completed_at" => if(line.done, do: now()),
                "completed_by_uuid" => if(line.done, do: actor_uuid),
                "created_by_uuid" => actor_uuid,
                "created_by_key_uuid" => key_uuid,
                "words_by_key_uuid" => key_uuid
              })
            )

          created =
            if line.tmp,
              do: Map.put(created, line.tmp, %{uuid: assignment.uuid, number: assignment.number}),
              else: created

          {%{line | id: assignment.uuid}, created}

        {line, _index}, created ->
          {line, created}
      end)

    {lines, created}
  end

  defp insert!(index, changeset) do
    case repo().insert(changeset) do
      {:ok, record} -> record
      {:error, cs} -> repo().rollback({:line, index, cs})
    end
  end

  defp rename_lines(lines, by_uuid, opts) do
    key_uuid = Keyword.get(opts, :key_uuid)

    for %{id: id, text: text} <- lines,
        %Assignment{task: %Task{} = task} = row <- [by_uuid[id]],
        task.title != text do
      case task |> Task.changeset(%{"title" => text}) |> repo().update() do
        {:ok, updated} ->
          # Whose words the title is now (the wording policy's question).
          if row.words_by_key_uuid != key_uuid do
            from(a in Assignment, where: a.uuid == ^row.uuid)
            |> repo().update_all(set: [words_by_key_uuid: key_uuid])
          end

          {row.uuid, updated}

        {:error, cs} ->
          repo().rollback({:line, id, cs})
      end
    end
  end

  # Bottom-up: a task is deleted only when nothing hangs on it and nothing
  # under it is staying; otherwise it is held. Returns `{removed, held}`.
  defp remove_rows([], _rows, _listed), do: {[], []}

  defp remove_rows(gone, rows, listed) do
    gone_uuids = MapSet.new(gone, & &1.uuid)
    carrying = carrying(Enum.map(gone, & &1.uuid))
    by_parent = Enum.group_by(rows, & &1.parent_uuid)

    # Deepest first, so a parent is judged after what is under it.
    depths = depths(rows)

    {delete, hold} =
      gone
      |> Enum.sort_by(&(-Map.get(depths, &1.uuid, 0)))
      |> Enum.reduce({MapSet.new(), MapSet.new()}, fn row, {delete, hold} ->
        children = Map.get(by_parent, row.uuid, [])

        # A child that stays listed is moved out from under it by the
        # nesting; one that is held, or was held before, pins it.
        pinned? =
          Enum.any?(children, fn child ->
            MapSet.member?(hold, child.uuid) or
              (child.review_status == "removed" and not MapSet.member?(listed, child.uuid)) or
              (not MapSet.member?(gone_uuids, child.uuid) and
                 not MapSet.member?(listed, child.uuid) and
                 child.review_status == "accepted")
          end)

        if pinned? or protected?(row, carrying),
          do: {delete, MapSet.put(hold, row.uuid)},
          else: {MapSet.put(delete, row.uuid), hold}
      end)

    delete = MapSet.to_list(delete)
    hold = MapSet.to_list(hold)

    if hold != [] do
      from(a in Assignment, where: a.uuid in ^hold)
      |> repo().update_all(set: [review_status: "removed", updated_at: now()])
    end

    if delete != [] do
      Enum.each(delete, &PhoenixKitProjects.Portal.delete_attachments_for/1)

      task_uuids =
        for row <- gone, row.uuid in delete, row.task && row.task.ad_hoc, do: row.task_uuid

      from(a in Assignment, where: a.uuid in ^delete) |> repo().delete_all()

      # A one-off task exists only for its row.
      if task_uuids != [] do
        used =
          from(a in Assignment, where: a.task_uuid in ^task_uuids, select: a.task_uuid)
          |> repo().all()

        orphans = task_uuids -- used
        if orphans != [], do: from(t in Task, where: t.uuid in ^orphans) |> repo().delete_all()
      end
    end

    {delete, hold}
  end

  @doc """
  Whether taking this task out of the list should hold it instead of
  deleting it: it carries something a stray keystroke must not destroy —
  logged hours or AI usage, a discussion or notes, a description, an owner,
  dates, an estimate, a dependency, or work already begun by someone.
  `carrying` is `carrying/1` for a set that includes the row.
  """
  @spec protected?(Assignment.t(), MapSet.t(binary())) :: boolean()
  def protected?(%Assignment{} = a, carrying) do
    MapSet.member?(carrying, a.uuid) or filled?(a.description) or
      not is_nil(a.assigned_person_uuid) or not is_nil(a.assigned_team_uuid) or
      not is_nil(a.assigned_department_uuid) or not is_nil(a.start_date) or
      not is_nil(a.end_date) or not is_nil(a.estimated_duration) or filled?(a.waiting_on) or
      a.status == "in_progress" or a.source != "internal" or a.public == true or
      (a.task && a.task.ad_hoc != true)
  end

  defp filled?(text), do: is_binary(text) and String.trim(text) != ""

  @doc "Among `uuids`: the tasks with logged entries, comments, notes or dependencies."
  @spec carrying([binary()]) :: MapSet.t(binary())
  def carrying([]), do: MapSet.new()

  def carrying(uuids) do
    ledger = PhoenixKitProjects.Ledger.totals_for_assignments(uuids)

    logged =
      for {uuid, t} <- ledger, t.minutes > 0 or t.tokens > 0 or t.cost_cents > 0, do: uuid

    comments = PhoenixKitProjects.Projects.comment_counts_for_assignments(uuids) |> Map.keys()
    notes = PhoenixKitProjects.TaskNotes.count_for_assignments(uuids) |> Map.keys()

    deps =
      from(d in PhoenixKitProjects.Schemas.Dependency,
        where: d.assignment_uuid in ^uuids or d.depends_on_uuid in ^uuids,
        select: [d.assignment_uuid, d.depends_on_uuid]
      )
      |> repo().all()
      |> List.flatten()

    MapSet.new(logged ++ comments ++ notes ++ deps) |> MapSet.intersection(MapSet.new(uuids))
  rescue
    # When in doubt, hold: a held task can be deleted, a deleted one cannot be held.
    _ -> MapSet.new(uuids)
  end

  # Lines → `[{uuid, parent_uuid}]`: a line sits under the nearest line
  # above it that is one level shallower.
  defp nest(lines) do
    {order, _stack} =
      Enum.map_reduce(lines, [], fn line, stack ->
        stack = Enum.take(stack, min(line.depth, length(stack)))
        parent = List.last(stack)
        {{line.id, parent}, stack ++ [line.id]}
      end)

    order
  end

  # Rows the lines do not mention (someone else's new task, a sub-project
  # row a list dropped) go back in right after the row that preceded them.
  defp weave(order, [], _rows), do: order

  defp weave(order, unlisted, rows) do
    placed = MapSet.new(order, &elem(&1, 0))
    server_order = Enum.map(rows, & &1.uuid)
    missing = Map.new(unlisted, &{&1.uuid, &1})

    {order, _placed} =
      Enum.reduce(server_order, {order, placed}, fn uuid, {order, placed} ->
        case Map.get(missing, uuid) do
          nil ->
            {order, placed}

          row ->
            parent =
              if row.parent_uuid && MapSet.member?(placed, row.parent_uuid), do: row.parent_uuid

            before = server_order |> Enum.take_while(&(&1 != uuid)) |> Enum.reverse()
            anchor = Enum.find(before, &MapSet.member?(placed, &1))
            {put_after(order, {uuid, parent}, anchor), MapSet.put(placed, uuid)}
        end
      end)

    order
  end

  defp put_after(order, entry, nil), do: [entry | order]

  defp put_after(order, entry, anchor) do
    Enum.flat_map(order, fn {uuid, _} = item ->
      if uuid == anchor, do: [item, entry], else: [item]
    end)
  end

  # ── Held tasks ─────────────────────────────────────────────────────

  @doc "The tasks taken out of a project's list and held, newest first."
  @spec held(binary()) :: [Assignment.t()]
  def held(project_uuid) when is_binary(project_uuid) do
    from(a in Assignment,
      where: a.project_uuid == ^project_uuid and a.review_status == "removed",
      order_by: [desc: a.updated_at],
      preload: [:task]
    )
    |> repo().all()
  end

  @doc "Puts a held task (and what is held under it) back in the list."
  @spec restore(Assignment.t()) :: {:ok, Assignment.t()} | {:error, term()}
  def restore(%Assignment{review_status: "removed"} = a) do
    rows =
      from(x in Assignment,
        where: x.project_uuid == ^a.project_uuid and x.review_status == "removed",
        select: %{uuid: x.uuid, parent_uuid: x.parent_uuid}
      )
      |> repo().all()

    uuids = [a.uuid | rows |> descendants(a.uuid) |> Enum.map(& &1.uuid)]

    from(x in Assignment, where: x.uuid in ^uuids)
    |> repo().update_all(set: [review_status: "accepted", updated_at: now()])

    restored = repo().get!(Assignment, a.uuid)
    settle_placed(restored)
    ProjectsPubSub.broadcast_assignment(:assignment_reordered, %{project_uuid: a.project_uuid})
    {:ok, restored}
  end

  def restore(%Assignment{} = a), do: {:ok, a}
end
